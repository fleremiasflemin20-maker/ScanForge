import Foundation

/// Finaliza una sesión de captura: escribe metadatos junto a las fotos para que
/// mac-reconstruct (o quien reciba la carpeta) sepa cómo se capturó.
enum CaptureExporter {
    struct Metadata: Codable {
        let objectName: String
        let createdAt: Date
        let usedLiDAR: Bool
        let photoCount: Int
    }

    static func finalize(_ session: CaptureSessionInfo) {
        let photoCount = countPhotos(in: session.folderURL)
        let metadata = Metadata(
            objectName: session.objectName,
            createdAt: session.createdAt,
            usedLiDAR: session.usedLiDAR,
            photoCount: photoCount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(metadata) else { return }
        let metadataURL = session.folderURL.appendingPathComponent("scanforge-session.json")
        try? data.write(to: metadataURL)
    }

    static func countPhotos(in folder: URL) -> Int {
        let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return 0
        }
        return contents.filter { extensions.contains($0.pathExtension.lowercased()) }.count
    }

    /// Todos los archivos de una sesión (fotos + profundidad + metadatos), para subirlos.
    static func allFiles(in folder: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }
}
