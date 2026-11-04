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

    /// Opciones de precisión que el Mac aplica al procesar (`scanforge-options.json`,
    /// lo lee scripts/receive_uploads.py).
    struct ScanOptions: Codable, Equatable {
        /// Lado más largo de la pieza medido con calibre, en mm: calibra la escala.
        var longestMM: Double?
        /// Pieza técnica: caras planas exactas y aristas vivas (ranuras, encajes).
        var mechanical = false
        /// División en partes: nil (no dividir), "shape" (anatomía) o "color".
        var partsBy: String?
        var partsColors = 4
        /// "pivote" (hexagonal), "espiga" (suelta) o "ninguno".
        var connector = "pivote"
        var clearanceMM = 0.2

        init() {}

        // Decodificación tolerante: los JSON de versiones anteriores no tienen todos
        // los campos.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            longestMM = try c.decodeIfPresent(Double.self, forKey: .longestMM)
            mechanical = try c.decodeIfPresent(Bool.self, forKey: .mechanical) ?? false
            partsBy = try c.decodeIfPresent(String.self, forKey: .partsBy)
            partsColors = try c.decodeIfPresent(Int.self, forKey: .partsColors) ?? 4
            connector = try c.decodeIfPresent(String.self, forKey: .connector) ?? "pivote"
            clearanceMM = try c.decodeIfPresent(Double.self, forKey: .clearanceMM) ?? 0.2
        }
    }

    static func loadOptions(for session: CaptureSessionInfo) -> ScanOptions {
        let url = session.folderURL.appendingPathComponent("scanforge-options.json")
        guard let data = try? Data(contentsOf: url),
              let options = try? JSONDecoder().decode(ScanOptions.self, from: data) else { return ScanOptions() }
        return options
    }

    static func saveOptions(_ options: ScanOptions, for session: CaptureSessionInfo) {
        let url = session.folderURL.appendingPathComponent("scanforge-options.json")
        if let data = try? JSONEncoder().encode(options) { try? data.write(to: url, options: .atomic) }
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
