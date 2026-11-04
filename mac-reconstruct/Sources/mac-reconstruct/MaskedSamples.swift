import CoreImage
import CoreVideo
import Foundation
import RealityKit
import Vision

/// Muestras de fotogrametría con máscara de objeto generada por Vision (recorte de
/// sujeto, macOS 14+). En plato giratorio la pieza gira y el fondo no: sin máscara,
/// el fondo estático confunde al cálculo de poses. Se cargan bajo demanda para no tener
/// cientos de fotos de 48 MP en memoria a la vez.
@available(macOS 15.0, *)
struct MaskedSampleSequence: Sequence {
    let urls: [URL]

    func makeIterator() -> AnyIterator<PhotogrammetrySample> {
        var index = 0
        return AnyIterator {
            while index < urls.count {
                defer { index += 1 }
                let url = urls[index]
                guard var sample = try? PhotogrammetrySample(contentsOf: url) else {
                    FileHandle.standardError.write(Data("⚠️  No se pudo leer \(url.lastPathComponent)\n".utf8))
                    continue
                }
                // PhotogrammetrySample(contentsOf:) asigna su propio id; usamos el índice
                // para poder relacionar después cada pose con su archivo.
                var withID = PhotogrammetrySample(id: index, image: sample.image)
                withID.depthDataMap = sample.depthDataMap
                withID.gravity = sample.gravity
                withID.metadata = sample.metadata
                withID.objectMask = ObjectMasker.mask(for: sample.image)
                sample = withID
                return sample
            }
            return nil
        }
    }
}

enum ObjectMasker {
    /// Máscara 8 bits (255 = pieza) del mismo tamaño que la imagen, o nil si Vision no
    /// encuentra un sujeto (entonces la muestra se usa sin máscara).
    static func mask(for image: CVPixelBuffer) -> CVPixelBuffer? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let scaled = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else { return nil }
        return toOneComponent8(scaled)
    }

    private static func toOneComponent8(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_OneComponent8 { return source }
        guard format == kCVPixelFormatType_OneComponent32Float else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent8, nil, &output)
        guard let output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(output) else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(source), dstStride = CVPixelBufferGetBytesPerRow(output)
        for y in 0..<height {
            let srcRow = (src + y * srcStride).assumingMemoryBound(to: Float32.self)
            let dstRow = (dst + y * dstStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                dstRow[x] = srcRow[x] > 0.5 ? 255 : 0
            }
        }
        return output
    }
}

/// Poses de cámara por archivo, para la escala con tablero ChArUco
/// (`python -m mesh_prep.charuco solve --poses poses.json`).
enum PoseWriter {
    @available(macOS 14.0, *)
    static func write(_ poses: PhotogrammetrySession.Poses, names: [Int: String], to url: URL) throws {
        var json: [String: [String: [Float]]] = [:]
        for (id, pose) in poses.posesBySample {
            guard let name = names[id] ?? poses.urlsBySample[id]?.lastPathComponent else { continue }
            let q = pose.rotation.vector
            json[name] = [
                "t": [pose.translation.x, pose.translation.y, pose.translation.z],
                "q": [q.x, q.y, q.z, q.w],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
