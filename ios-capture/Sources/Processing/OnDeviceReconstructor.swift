import Foundation
import RealityKit

/// Reconstrucción fotogramétrica en el propio iPhone (PhotogrammetrySession en iOS 17+,
/// dispositivos con LiDAR). Igual que el MIRACO de Revopoint, que procesa sin PC:
/// fotos de Object Capture → USDZ texturizado → STL/OBJ en mm para el slicer.
@MainActor
final class OnDeviceReconstructor: ObservableObject {
    enum State: Equatable {
        case idle
        case running(progress: Double)
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    static var isSupported: Bool {
        if #available(iOS 17.0, *) { return PhotogrammetrySession.isSupported }
        return false
    }

    func reconstruct(_ session: CaptureSessionInfo, completion: @escaping () -> Void) {
        guard #available(iOS 17.0, *) else {
            state = .failed("Necesita iOS 17 o superior.")
            return
        }
        guard PhotogrammetrySession.isSupported else {
            state = .failed("Este iPhone no puede reconstruir en el dispositivo. Usa el Mac (mac-reconstruct).")
            return
        }
        state = .running(progress: 0)

        let modelURL = session.exportFolderURL.appendingPathComponent("\(session.safeBaseName).usdz")
        let exportFolder = session.exportFolderURL
        let baseName = session.safeBaseName

        task = Task {
            do {
                var configuration = PhotogrammetrySession.Configuration()
                configuration.checkpointDirectory = session.checkpointFolderURL
                configuration.featureSensitivity = .normal
                configuration.sampleOrdering = .sequential
                let photogrammetry = try PhotogrammetrySession(input: session.folderURL, configuration: configuration)
                try photogrammetry.process(requests: [.modelFile(url: modelURL)])

                for try await output in photogrammetry.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        state = .running(progress: fraction)
                    case .requestError(_, let error):
                        state = .failed("Error en la reconstrucción: \(error.localizedDescription)")
                    case .processingComplete:
                        if case .failed = state { break }
                        await Self.convertForPrinting(modelURL: modelURL, folder: exportFolder, baseName: baseName)
                        state = .finished
                        completion()
                    case .processingCancelled:
                        state = .idle
                    default:
                        break
                    }
                }
            } catch {
                state = .failed("No se pudo reconstruir: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// USDZ (metros, Y arriba) → STL y OBJ (mm, Z arriba) para Bambu Studio / Creality Print.
    nonisolated private static func convertForPrinting(modelURL: URL, folder: URL, baseName: String) async {
        await Task.detached(priority: .userInitiated) {
            guard let mesh = try? MeshExporter.mesh(fromModelAt: modelURL) else { return }
            try? MeshExporter.writeSTL(mesh, to: folder.appendingPathComponent("\(baseName).stl"))
            try? MeshExporter.writeOBJ(mesh, to: folder.appendingPathComponent("\(baseName).obj"))
        }.value
    }
}
