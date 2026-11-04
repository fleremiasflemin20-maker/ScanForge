import Foundation

/// Los cuatro modos de escaneo de ScanForge Pro. Cada uno reproduce, con los sensores
/// del iPhone 17 Pro, una de las tecnologías de los escáneres dedicados:
///
/// - `objectCapture`: fotogrametría guiada + LiDAR (como el modo "textura alta" de los
///   escáneres con cámara RGB), reconstruida en el propio iPhone.
/// - `lidarFusion`: fusión en tiempo real de profundidad LiDAR con seguimiento
///   visual-inercial de ARKit (equivalente al seguimiento híbrido de los escáneres
///   de mano para objetos grandes).
/// - `trueDepthMicro`: luz estructurada infrarroja (proyector de puntos TrueDepth) con
///   seguimiento por geometría ICP — el mismo principio que el modo NIR de Creality
///   Raptor / Revopoint, para piezas pequeñas.
/// - `manualPhotos`: fotos a 48 MP para reconstruir en el Mac (iPhones sin LiDAR).
enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case objectCapture
    case lidarFusion
    case trueDepthMicro
    case manualPhotos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .objectCapture: return "Objeto Pro"
        case .lidarFusion: return "LiDAR Fusión"
        case .trueDepthMicro: return "Micro TrueDepth"
        case .manualPhotos: return "Fotos 48 MP"
        }
    }

    var subtitle: String {
        switch self {
        case .objectCapture:
            return "Fotogrametría guiada + LiDAR. Máximo detalle y textura, reconstruido en el iPhone."
        case .lidarFusion:
            return "Nube de puntos en tiempo real con escala real. Objetos medianos y grandes (20 cm – 3 m)."
        case .trueDepthMicro:
            return "Luz estructurada infrarroja + seguimiento ICP. Piezas pequeñas (3 – 20 cm) en plataforma giratoria."
        case .manualPhotos:
            return "Fotos a resolución completa para reconstruir en el Mac con detalle máximo."
        }
    }

    /// Etiqueta para orientar la elección en la pantalla de inicio.
    var badge: String? {
        switch self {
        case .objectCapture: return "Recomendado"
        case .lidarFusion: return "Piezas grandes"
        case .trueDepthMicro: return "Piezas pequeñas"
        case .manualPhotos: return "Máximo detalle (Mac)"
        }
    }

    var systemImage: String {
        switch self {
        case .objectCapture: return "cube.transparent"
        case .lidarFusion: return "dot.radiowaves.left.and.right"
        case .trueDepthMicro: return "faceid"
        case .manualPhotos: return "camera.aperture"
        }
    }

    var usesLiDAR: Bool { self == .objectCapture || self == .lidarFusion }
}

/// Metadatos de una sesión de captura.
struct CaptureSessionInfo: Identifiable, Codable, Hashable {
    let id: UUID
    var objectName: String
    let createdAt: Date
    let mode: ScanMode
    var photoCount: Int
    let folderURL: URL

    var usedLiDAR: Bool { mode.usesLiDAR }

    /// Subcarpeta con los modelos exportados (USDZ, STL, OBJ, PLY).
    var exportFolderURL: URL {
        let url = folderURL.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Checkpoints de Object Capture (aceleran la reconstrucción en el iPhone). Van en
    /// Caches y NO dentro de la carpeta de fotos: ObjectCaptureSession exige que la
    /// carpeta de imágenes esté vacía al empezar; si no, la sesión falla en silencio
    /// ("Cannot make a view for a deinitialized ObjectCaptureSession").
    var checkpointFolderURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches
            .appendingPathComponent("ScanForgeCheckpoints", isDirectory: true)
            .appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Nombre de archivo seguro para los exportados (p.ej. "jarron-001").
    var safeBaseName: String { CaptureStorage.safeName(objectName) }

    init(objectName: String, mode: ScanMode, folderURL: URL) {
        self.id = UUID()
        self.objectName = objectName
        self.createdAt = Date()
        self.mode = mode
        self.photoCount = 0
        self.folderURL = folderURL
    }
}

/// Protocolo de plato giratorio (Artec/OpenScan): 3 anillos a distintas alturas y uno
/// más con la pieza volteada para capturar la base.
enum CapturePhase: Equatable {
    case low, mid, high, flip

    var label: String {
        switch self {
        case .low: return "altura baja"
        case .mid: return "altura media"
        case .high: return "altura alta"
        case .flip: return "pieza volteada (base)"
        }
    }

    /// Qué tiene que hacer el usuario al empezar esta fase.
    var instruction: String {
        switch self {
        case .low: return "Cámara baja, casi a la altura de la pieza."
        case .mid: return "Sube la cámara: mira la pieza a unos 30° desde arriba."
        case .high: return "Sube más: mira la pieza a unos 60° desde arriba."
        case .flip: return "Voltea la pieza (base hacia arriba) y vuelve a la altura media."
        }
    }

    var next: CapturePhase? {
        switch self {
        case .low: return .mid
        case .mid: return .high
        case .high: return .flip
        case .flip: return nil
        }
    }
}


/// Carpeta raíz donde ScanForge guarda todas las capturas, lista para subir al Mac,
/// compartir, o abrir desde la app Archivos (On My iPhone → ScanForge).
enum CaptureStorage {
    static var capturesRootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("ScanForgeCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func safeName(_ objectName: String) -> String {
        let trimmed = objectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "objeto" : cleaned
    }

    static func newSessionFolder(objectName: String) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = capturesRootURL.appendingPathComponent("\(safeName(objectName))-\(timestamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
