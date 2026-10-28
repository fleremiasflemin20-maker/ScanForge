import ARKit
import Foundation
import ModelIO
import simd

/// Malla triangular simple, independiente de ARKit/ModelIO, para exportar a los
/// formatos que entienden los slicers (Bambu Studio, Creality Print, OrcaSlicer, Cura).
struct TriangleMesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }

    mutating func append(_ other: TriangleMesh) {
        let offset = UInt32(positions.count)
        positions.append(contentsOf: other.positions)
        indices.append(contentsOf: other.indices.map { $0 + offset })
    }

    /// Quita triángulos cuyos tres vértices están fuera de la esfera de recorte.
    func cropped(center: SIMD3<Float>?, radius: Float) -> TriangleMesh {
        guard let center else { return self }
        var out = TriangleMesh()
        var remap = [UInt32: UInt32]()
        let r2 = radius * radius
        for t in stride(from: 0, to: indices.count, by: 3) {
            let tri = [indices[t], indices[t + 1], indices[t + 2]]
            let inside = tri.contains { simd_distance_squared(positions[Int($0)], center) <= r2 }
            guard inside else { continue }
            for i in tri {
                if let mapped = remap[i] {
                    out.indices.append(mapped)
                } else {
                    let mapped = UInt32(out.positions.count)
                    out.positions.append(positions[Int(i)])
                    remap[i] = mapped
                    out.indices.append(mapped)
                }
            }
        }
        return out
    }
}

/// ARKit/RealityKit trabajan en metros con Y hacia arriba; los slicers asumen
/// milímetros con Z hacia arriba. Esta conversión hace que el STL salga a escala real
/// y "de pie" sobre la cama al importarlo.
enum PrintSpace {
    @inline(__always)
    static func fromARKit(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.x, -p.z, p.y) * 1000
    }

    @inline(__always)
    static func directionFromARKit(_ n: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(n.x, -n.z, n.y)
    }
}

enum MeshExporter {
    enum ExportError: LocalizedError {
        case emptyMesh
        case unreadableModel

        var errorDescription: String? {
            switch self {
            case .emptyMesh: return "La malla está vacía: escanea un poco más antes de exportar."
            case .unreadableModel: return "No se pudo leer el modelo reconstruido."
            }
        }
    }

    // MARK: - Fuentes

    /// Une las mallas que ARKit reconstruye con el LiDAR (ARMeshAnchor) en coordenadas
    /// de mundo.
    static func mesh(from anchors: [ARMeshAnchor]) -> TriangleMesh {
        var result = TriangleMesh()
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            var part = TriangleMesh()

            let vertices = geometry.vertices
            let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset)
            part.positions.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let v = vertexPointer.advanced(by: i * vertices.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let world = transform * SIMD4<Float>(v.0, v.1, v.2, 1)
                part.positions.append(SIMD3<Float>(world.x, world.y, world.z))
            }

            let faces = geometry.faces
            let facePointer = faces.buffer.contents()
            let indicesPerFace = faces.indexCountPerPrimitive
            part.indices.reserveCapacity(faces.count * 3)
            for f in 0..<faces.count {
                for k in 0..<min(indicesPerFace, 3) {
                    let offset = (f * indicesPerFace + k) * faces.bytesPerIndex
                    let index: UInt32
                    if faces.bytesPerIndex == 2 {
                        index = UInt32(facePointer.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                    } else {
                        index = facePointer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
                    }
                    part.indices.append(index)
                }
            }
            result.append(part)
        }
        return result
    }

    /// Lee un USDZ/OBJ con ModelIO y aplana todas sus mallas a una sola, en metros.
    static func mesh(fromModelAt url: URL) throws -> TriangleMesh {
        let asset = MDLAsset(url: url)
        var result = TriangleMesh()
        for case let mdlMesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            guard let attribute = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
                continue
            }
            let global = MDLTransform.globalTransform(with: mdlMesh, atTime: 0)
            var part = TriangleMesh()
            part.positions.reserveCapacity(mdlMesh.vertexCount)
            for i in 0..<mdlMesh.vertexCount {
                let v = attribute.dataStart.advanced(by: i * attribute.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let world = global * SIMD4<Float>(v.0, v.1, v.2, 1)
                part.positions.append(SIMD3<Float>(world.x, world.y, world.z))
            }
            for case let submesh as MDLSubmesh in mdlMesh.submeshes ?? [] {
                guard submesh.geometryType == .triangles else { continue }
                let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = indexBuffer.map()
                let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
                part.indices.append(contentsOf: UnsafeBufferPointer(start: pointer, count: submesh.indexCount))
            }
            result.append(part)
        }
        guard !result.isEmpty else { throw ExportError.unreadableModel }
        return result
    }

    // MARK: - Escritura

    /// STL binario en milímetros, Z arriba: listo para el slicer.
    static func writeSTL(_ mesh: TriangleMesh, to url: URL, convertFromARKit: Bool = true) throws {
        guard !mesh.isEmpty else { throw ExportError.emptyMesh }
        let points = convertFromARKit ? mesh.positions.map(PrintSpace.fromARKit) : mesh.positions
        let triangles = mesh.triangleCount

        var data = Data(count: 80)
        data.reserveCapacity(84 + triangles * 50)
        var count = UInt32(triangles).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        func append(_ v: SIMD3<Float>) {
            for f in [v.x, v.y, v.z] {
                var le = f.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        }

        for t in 0..<triangles {
            let a = points[Int(mesh.indices[t * 3])]
            let b = points[Int(mesh.indices[t * 3 + 1])]
            let c = points[Int(mesh.indices[t * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            append(length > 0 ? n / length : SIMD3<Float>(0, 0, 1))
            append(a)
            append(b)
            append(c)
            data.append(contentsOf: [0, 0])
        }
        try data.write(to: url, options: .atomic)
    }

    /// OBJ en milímetros, Z arriba.
    static func writeOBJ(_ mesh: TriangleMesh, to url: URL, convertFromARKit: Bool = true) throws {
        guard !mesh.isEmpty else { throw ExportError.emptyMesh }
        var text = "# ScanForge Pro — unidades: mm, Z arriba\n"
        text.reserveCapacity(mesh.positions.count * 40 + mesh.indices.count * 8)
        for p in mesh.positions {
            let v = convertFromARKit ? PrintSpace.fromARKit(p) : p
            text += "v \(v.x) \(v.y) \(v.z)\n"
        }
        for t in 0..<mesh.triangleCount {
            text += "f \(mesh.indices[t * 3] + 1) \(mesh.indices[t * 3 + 1] + 1) \(mesh.indices[t * 3 + 2] + 1)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Exporta una nube fusionada como PLY (mm, Z arriba) para mallar con mesh-prep
    /// (`mesh-prep --input nube.ply`, reconstrucción de Poisson).
    static func writePointCloud(_ snapshot: VoxelCloud.Snapshot, to url: URL) throws {
        guard !snapshot.positions.isEmpty else { throw ExportError.emptyMesh }
        try PLYWriter.write(
            snapshot, to: url,
            transform: PrintSpace.fromARKit,
            normalTransform: PrintSpace.directionFromARKit
        )
    }
}
