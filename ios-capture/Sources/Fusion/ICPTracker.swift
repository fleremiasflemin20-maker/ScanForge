import Foundation
import simd

/// Seguimiento por geometría con ICP punto-a-plano (Iterative Closest Point).
///
/// Es la técnica con la que los escáneres de luz estructurada (Revopoint, modo NIR de
/// Creality Raptor/Otter, EinScan) saben dónde está el sensor sin marcadores: cada
/// fotograma de profundidad nuevo se alinea contra el modelo ya fusionado, y la
/// transformación que mejor encaja las superficies es la pose del fotograma.
enum ICPTracker {
    struct Result {
        var pose: simd_float4x4
        /// Fracción de puntos que encontraron correspondencia en el modelo.
        var inlierRatio: Float
        /// Error cuadrático medio punto-a-plano en metros.
        var rmse: Float
        var iterations: Int
    }

    /// Alinea `points` (coordenadas de cámara) contra `model`, partiendo de `initialPose`
    /// (cámara → modelo). La distancia de búsqueda se reduce en cada iteración
    /// (de grueso a fino) para converger aunque el movimiento entre fotogramas sea de
    /// varios milímetros.
    static func align(
        points: [SIMD3<Float>],
        to model: VoxelCloud,
        initialPose: simd_float4x4,
        maxIterations: Int = 15,
        startDistance: Float = 0.015,
        endDistance: Float = 0.004
    ) -> Result {
        var pose = initialPose
        var inliers = 0
        var errorSum: Double = 0
        var iteration = 0

        while iteration < maxIterations {
            let t = Float(iteration) / Float(max(maxIterations - 1, 1))
            let maxDistance = startDistance + (endDistance - startDistance) * t

            var ata = [Double](repeating: 0, count: 36)
            var atb = [Double](repeating: 0, count: 6)
            inliers = 0
            errorSum = 0

            for p in points {
                let q4 = pose * SIMD4<Float>(p, 1)
                let q = SIMD3<Float>(q4.x, q4.y, q4.z)
                guard let match = model.nearest(to: q, maxDistance: maxDistance) else { continue }
                let n = match.normal
                guard simd_length_squared(n) > 0.5 else { continue }

                let residual = Double(simd_dot(q - match.position, n))
                let c = simd_cross(q, n)
                let row: [Double] = [Double(c.x), Double(c.y), Double(c.z), Double(n.x), Double(n.y), Double(n.z)]
                for i in 0..<6 {
                    atb[i] -= row[i] * residual
                    for j in i..<6 {
                        ata[i * 6 + j] += row[i] * row[j]
                    }
                }
                inliers += 1
                errorSum += residual * residual
            }

            guard inliers >= 30 else { break }
            for i in 0..<6 {
                for j in 0..<i { ata[i * 6 + j] = ata[j * 6 + i] }
            }
            guard let x = solve6x6(ata, atb) else { break }

            let omega = SIMD3<Float>(Float(x[0]), Float(x[1]), Float(x[2]))
            let translation = SIMD3<Float>(Float(x[3]), Float(x[4]), Float(x[5]))
            let delta = rigidTransform(rotationVector: omega, translation: translation)
            pose = delta * pose
            iteration += 1

            if simd_length(omega) < 1e-5 && simd_length(translation) < 1e-5 { break }
        }

        let ratio = points.isEmpty ? 0 : Float(inliers) / Float(points.count)
        let rmse = inliers > 0 ? Float(sqrt(errorSum / Double(inliers))) : .infinity
        return Result(pose: pose, inlierRatio: ratio, rmse: rmse, iterations: iteration)
    }

    /// Rotación de Rodrigues + traslación como matriz 4x4.
    static func rigidTransform(rotationVector omega: SIMD3<Float>, translation: SIMD3<Float>) -> simd_float4x4 {
        let angle = simd_length(omega)
        let rotation: simd_float3x3
        if angle < 1e-8 {
            rotation = matrix_identity_float3x3
        } else {
            rotation = simd_float3x3(simd_quatf(angle: angle, axis: omega / angle))
        }
        return simd_float4x4(
            SIMD4<Float>(rotation.columns.0, 0),
            SIMD4<Float>(rotation.columns.1, 0),
            SIMD4<Float>(rotation.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    /// Eliminación gaussiana con pivoteo parcial para el sistema normal 6x6.
    static func solve6x6(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b
        for col in 0..<6 {
            var pivot = col
            for row in (col + 1)..<6 where abs(m[row * 6 + col]) > abs(m[pivot * 6 + col]) {
                pivot = row
            }
            guard abs(m[pivot * 6 + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<6 { m.swapAt(col * 6 + k, pivot * 6 + k) }
                v.swapAt(col, pivot)
            }
            for row in (col + 1)..<6 {
                let factor = m[row * 6 + col] / m[col * 6 + col]
                if factor == 0 { continue }
                for k in col..<6 { m[row * 6 + k] -= factor * m[col * 6 + k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: 6)
        for row in stride(from: 5, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<6 { sum -= m[row * 6 + k] * x[k] }
            x[row] = sum / m[row * 6 + row]
        }
        return x
    }
}

/// Plano detectado por RANSAC (la mesa o la plataforma giratoria), en la forma
/// n·p + d = 0, orientado para que la cámara quede en el lado positivo.
struct DetectedPlane {
    var normal: SIMD3<Float>
    var d: Float

    func signedDistance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p) + d }

    static func ransac(points: [SIMD3<Float>], iterations: Int = 250, threshold: Float = 0.004, minInlierRatio: Float = 0.2) -> DetectedPlane? {
        guard points.count >= 100 else { return nil }
        var best: DetectedPlane?
        var bestInliers = 0
        var generator = SystemRandomNumberGenerator()
        let sampleStride = max(1, points.count / 3000)
        for _ in 0..<iterations {
            let a = points[Int.random(in: 0..<points.count, using: &generator)]
            let b = points[Int.random(in: 0..<points.count, using: &generator)]
            let c = points[Int.random(in: 0..<points.count, using: &generator)]
            var n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 1e-6 else { continue }
            n /= length
            var d = -simd_dot(n, a)
            // La cámara (origen) en el lado positivo.
            if d < 0 { n = -n; d = -d }
            var count = 0
            for i in stride(from: 0, to: points.count, by: sampleStride) where abs(simd_dot(n, points[i]) + d) < threshold {
                count += 1
            }
            if count > bestInliers {
                bestInliers = count
                best = DetectedPlane(normal: n, d: d)
            }
        }
        let sampled = (points.count + sampleStride - 1) / sampleStride
        guard Float(bestInliers) / Float(sampled) >= minInlierRatio else { return nil }
        return best
    }
}
