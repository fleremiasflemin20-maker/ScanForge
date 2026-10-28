import ARKit
import AVFoundation
import Foundation
import RealityKit
import SwiftUI

/// Qué sensores tiene este iPhone. Se decide en tiempo de ejecución, así la misma app
/// funciona en el 17 Pro (todos los modos) y en iPhones sin LiDAR (solo fotos/TrueDepth).
struct DeviceCapabilities {
    let objectCapture: Bool
    let lidarDepth: Bool
    let trueDepth: Bool
    let reconstructOnDevice: Bool

    static func detect() -> DeviceCapabilities {
        let objectCapture: Bool
        let reconstruct: Bool
        if #available(iOS 17.0, *) {
            objectCapture = ObjectCaptureSession.isSupported
            reconstruct = PhotogrammetrySession.isSupported
        } else {
            objectCapture = false
            reconstruct = false
        }
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
        return DeviceCapabilities(
            objectCapture: objectCapture,
            lidarDepth: lidar,
            trueDepth: trueDepth,
            reconstructOnDevice: reconstruct
        )
    }

    func supports(_ mode: ScanMode) -> Bool {
        switch mode {
        case .objectCapture: return objectCapture
        case .lidarFusion: return lidarDepth
        case .trueDepthMicro: return trueDepth
        case .manualPhotos: return true
        }
    }
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published var activeSession: CaptureSessionInfo?

    let capabilities = DeviceCapabilities.detect()

    func beginSession(objectName: String, mode: ScanMode) -> CaptureSessionInfo {
        let folder = CaptureStorage.newSessionFolder(objectName: objectName)
        let info = CaptureSessionInfo(objectName: objectName, mode: mode, folderURL: folder)
        activeSession = info
        return info
    }

    func endSession() {
        activeSession = nil
    }
}
