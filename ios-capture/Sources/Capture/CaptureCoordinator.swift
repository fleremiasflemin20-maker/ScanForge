import Foundation
import RealityKit
import SwiftUI

/// Decide en tiempo de ejecución si el dispositivo soporta la captura guiada con
/// LiDAR (ObjectCaptureSession) o si hay que usar el modo manual con AVFoundation.
/// El iPhone 17 Pro tiene LiDAR, así que normalmente se usará la ruta guiada, pero
/// este chequeo permite que la misma app funcione en cualquier iPhone.
enum CaptureMode {
    case lidarGuided
    case manual

    @available(iOS 17.0, *)
    static func detect() -> CaptureMode {
        ObjectCaptureSession.isSupported ? .lidarGuided : .manual
    }
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published var activeSession: CaptureSessionInfo?
    @Published var isCapturing = false

    let mode: CaptureMode

    init() {
        if #available(iOS 17.0, *) {
            self.mode = CaptureMode.detect()
        } else {
            self.mode = .manual
        }
    }

    func beginSession(objectName: String) -> CaptureSessionInfo {
        let folder = CaptureStorage.newSessionFolder(objectName: objectName)
        let info = CaptureSessionInfo(
            objectName: objectName,
            usedLiDAR: mode == .lidarGuided,
            folderURL: folder
        )
        activeSession = info
        isCapturing = true
        return info
    }

    func endSession() {
        isCapturing = false
    }
}
