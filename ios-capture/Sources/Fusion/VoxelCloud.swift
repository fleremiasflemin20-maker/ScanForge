import Foundation
import simd

/// Nube de puntos fusionada sobre una rejilla de vóxeles (hash espacial).
///
/// Es la misma idea que usan los escáneres de mano (Creality Raptor, Revopoint, Artec)
/// para su vista previa en tiempo real: cada medición de profundidad cae en un vóxel y
/// se promedia con las anteriores (posición, color y normal). Así el ruido de cada
/// fotograma se cancela y las superficies vistas varias veces quedan más precisas.
///
/// No es thread-safe: úsala siempre desde la misma cola.
final class VoxelCloud: @unchecked Sendable {
    struct Voxel {
        var position = SIMD3<Float>(repeating: 0)
        var color = SIMD3<Float>(repeating: 0)
        var normal = SIMD3<Float>(repeating: 0)
        var weight: Float = 0
        var observations: UInt16 = 0

        var mean: SIMD3<Float> { position / max(weight, 1e-6) }
        var meanColor: SIMD3<Float> { color / max(weight, 1e-6) }
        var meanNormal: SIMD3<Float> {
            let length = simd_length(normal)
            return length > 1e-6 ? normal / length : SIMD3<Float>(0, 0, 0)
        }
    }

    /// Lado del vóxel en metros.
    let voxelSize: Float
    private(set) var voxels: [Int64: Voxel] = [:]

    init(voxelSize: Float) {
        self.voxelSize = voxelSize
        voxels.reserveCapacity(200_000)
    }

    var count: Int { voxels.count }

    @inline(__always)
    func cellIndex(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(
            Int32((p.x / voxelSize).rounded(.down)),
            Int32((p.y / voxelSize).rounded(.down)),
            Int32((p.z / voxelSize).rounded(.down))
        )
    }

    /// Empaqueta tres índices de 21 bits en un Int64 (±1 millón de vóxeles por eje:
    /// con vóxel de 1 mm son ±1 km, de sobra).
    @inline(__always)
    static func key(_ c: SIMD3<Int32>) -> Int64 {
        let mask: Int64 = 0x1F_FFFF
        return ((Int64(c.x) & mask) << 42) | ((Int64(c.y) & mask) << 21) | (Int64(c.z) & mask)
    }

    func add(point: SIMD3<Float>, color: SIMD3<Float>, normal: SIMD3<Float>, weight: Float = 1) {
        let k = Self.key(cellIndex(point))
        var v = voxels[k] ?? Voxel()
        v.position += point * weight
        v.color += color * weight
        v.normal += normal * weight
        v.weight += weight
        if v.observations < UInt16.max { v.observations += 1 }
        voxels[k] = v
    }

    /// Vóxel más cercano a `point` buscando en los 27 vóxeles vecinos.
    /// Devuelve la posición media y la normal media del vóxel encontrado.
    func nearest(to point: SIMD3<Float>, maxDistance: Float) -> (position: SIMD3<Float>, normal: SIMD3<Float>)? {
        let c = cellIndex(point)
        var best: (SIMD3<Float>, SIMD3<Float>)?
        var bestDistance = maxDistance * maxDistance
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 {
                    guard let v = voxels[Self.key(c &+ SIMD3<Int32>(dx, dy, dz))] else { continue }
                    let m = v.mean
                    let d = simd_distance_squared(m, point)
                    if d < bestDistance {
                        bestDistance = d
                        best = (m, v.meanNormal)
                    }
                }
            }
        }
        return best
    }

    func removeAll() {
        voxels.removeAll(keepingCapacity: true)
    }

    struct Snapshot {
        var positions: [SIMD3<Float>]
        var colors: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
    }

    /// Copia de los puntos con al menos `minObservations` mediciones (filtro de ruido:
    /// un punto visto una sola vez suele ser un reflejo o un borde volando).
    /// `stride` > 1 submuestrea para la vista previa en vivo.
    func snapshot(minObservations: UInt16 = 1, stride: Int = 1, limit: Int = .max) -> Snapshot {
        var snap = Snapshot(positions: [], colors: [], normals: [])
        let estimate = min(voxels.count / max(stride, 1) + 1, limit)
        snap.positions.reserveCapacity(estimate)
        snap.colors.reserveCapacity(estimate)
        snap.normals.reserveCapacity(estimate)
        var i = 0
        for v in voxels.values where v.observations >= minObservations {
            defer { i += 1 }
            if i % stride != 0 { continue }
            snap.positions.append(v.mean)
            snap.colors.append(v.meanColor)
            snap.normals.append(v.meanNormal)
            if snap.positions.count >= limit { break }
        }
        return snap
    }
}

/// Escritura de nubes de puntos en PLY binario (lo abren MeshLab, CloudCompare,
/// Blender, mesh-prep y la mayoría de software de escáneres).
enum PLYWriter {
    /// `transform` permite pasar a coordenadas de impresión (Z arriba, milímetros).
    static func write(_ snapshot: VoxelCloud.Snapshot, to url: URL, transform: (SIMD3<Float>) -> SIMD3<Float> = { $0 }, normalTransform: (SIMD3<Float>) -> SIMD3<Float> = { $0 }) throws {
        let count = snapshot.positions.count
        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "comment ScanForge Pro\n"
        header += "element vertex \(count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + count * 27)
        for i in 0..<count {
            let p = transform(snapshot.positions[i])
            let n = normalTransform(snapshot.normals[i])
            for f in [p.x, p.y, p.z, n.x, n.y, n.z] {
                var le = f.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
            let c = simd_clamp(snapshot.colors[i], SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * 255
            data.append(contentsOf: [UInt8(c.x), UInt8(c.y), UInt8(c.z)])
        }
        try data.write(to: url, options: .atomic)
    }
}
