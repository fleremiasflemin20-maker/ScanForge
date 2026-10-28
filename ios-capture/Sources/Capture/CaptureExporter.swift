import Foundation

/// Finaliza una sesión de captura: escribe metadatos junto a las fotos para que
/// mac-reconstruct (o quien reciba la carpeta) sepa cómo se capturó.
enum CaptureExporter {
    struct Metadata: Codable {
        let objectName: String
        let createdAt: Date
        let mode: String
        let usedLiDAR: Bool
        let photoCount: Int
        let exports: [String]
    }

    static func finalize(_ session: CaptureSessionInfo) {
        let metadata = Metadata(
            objectName: session.objectName,
            createdAt: session.createdAt,
            mode: session.mode.rawValue,
            usedLiDAR: session.usedLiDAR,
            photoCount: countPhotos(in: session.folderURL),
            exports: exportedFiles(for: session).map(\.lastPathComponent)
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

    /// Modelos exportados de la sesión (USDZ/STL/OBJ/PLY), ordenados por nombre.
    static func exportedFiles(for session: CaptureSessionInfo) -> [URL] {
        let folder = session.folderURL.appendingPathComponent("Export", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { ["usdz", "stl", "obj", "ply"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Todos los archivos de una sesión (fotos + profundidad + metadatos + exportados),
    /// para subirlos. Omite los checkpoints internos de Object Capture.
    static func allFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains("Checkpoints") { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }
}
