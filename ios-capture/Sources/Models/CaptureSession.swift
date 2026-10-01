import Foundation

/// Metadatos de una sesión de captura (independiente de si se usó LiDAR o modo manual).
struct CaptureSessionInfo: Identifiable, Codable {
    let id: UUID
    var objectName: String
    let createdAt: Date
    let usedLiDAR: Bool
    var photoCount: Int
    let folderURL: URL

    init(objectName: String, usedLiDAR: Bool, folderURL: URL) {
        self.id = UUID()
        self.objectName = objectName
        self.createdAt = Date()
        self.usedLiDAR = usedLiDAR
        self.photoCount = 0
        self.folderURL = folderURL
    }
}

enum CapturePhase: Equatable {
    case low, mid, high

    var label: String {
        switch self {
        case .low: return "altura baja"
        case .mid: return "altura media"
        case .high: return "altura alta"
        }
    }

    var next: CapturePhase? {
        switch self {
        case .low: return .mid
        case .mid: return .high
        case .high: return nil
        }
    }
}

/// Carpeta raíz donde ScanForge guarda todas las capturas, lista para subir al Mac
/// o para copiar manualmente a mac-reconstruct.
enum CaptureStorage {
    static var capturesRootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("ScanForgeCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func newSessionFolder(objectName: String) -> URL {
        let safeName = objectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let name = safeName.isEmpty ? "objeto" : safeName
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = capturesRootURL.appendingPathComponent("\(name)-\(timestamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
