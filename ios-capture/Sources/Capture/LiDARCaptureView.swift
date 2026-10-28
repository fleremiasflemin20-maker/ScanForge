import RealityKit
import SwiftUI

/// Envuelve `ObjectCaptureSession` + `ObjectCaptureView` (RealityKit, iOS 17+) para la
/// captura guiada en dispositivos con LiDAR. Apple dibuja la guía (cúpula de cobertura,
/// "acércate", "más luz"); nosotros llevamos el flujo de estados:
/// ready → detecting (caja del objeto) → capturing → pasada completada → (girar) → finish.
@available(iOS 17.0, *)
struct LiDARCaptureView: View {
    let sessionInfo: CaptureSessionInfo
    let onFinished: (CaptureSessionInfo) -> Void
    let onCancelled: () -> Void

    @State private var captureSession = ObjectCaptureSession()
    @State private var stage: Stage = .initializing
    @State private var passCompleted = false
    @State private var passCount = 1
    @State private var errorMessage: String?

    /// Copia simple del estado de la sesión: evita depender de si `CaptureState` es
    /// Equatable (tiene `.failed(Error)`), y se actualiza desde `stateUpdates`.
    private enum Stage {
        case initializing, ready, detecting, capturing, finishing, completed, failed
    }

    var body: some View {
        ZStack {
            ObjectCaptureView(session: captureSession)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Cancelar") {
                        captureSession.cancel()
                        onCancelled()
                    }
                    .buttonStyle(OverlayButtonStyle())
                    Spacer()
                    if stage == .capturing {
                        Text("Pasada \(passCount)")
                            .font(.footnote.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding()

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .padding(8)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                hint
                controls
                    .padding(.bottom, 32)
            }
        }
        .task {
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = sessionInfo.checkpointFolderURL
            configuration.isOverCaptureEnabled = true
            captureSession.start(imagesDirectory: sessionInfo.folderURL, configuration: configuration)
        }
        .task {
            for await state in captureSession.stateUpdates {
                apply(state)
            }
        }
        .task {
            for await completed in captureSession.userCompletedScanPassUpdates {
                passCompleted = completed
            }
        }
    }

    private func apply(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .initializing: stage = .initializing
        case .ready: stage = .ready
        case .detecting: stage = .detecting
        case .capturing: stage = .capturing
        case .finishing: stage = .finishing
        case .completed:
            stage = .completed
            onFinished(sessionInfo)
        case .failed(let error):
            stage = .failed
            errorMessage = "La captura falló: \(error.localizedDescription)"
        @unknown default:
            break
        }
    }

    @ViewBuilder
    private var hint: some View {
        let text: String? = {
            switch stage {
            case .initializing: return "Iniciando LiDAR…"
            case .ready: return "Apunta al objeto con el punto central"
            case .detecting: return "Ajusta la caja para que envuelva el objeto"
            case .capturing where passCompleted:
                return "Pasada completa. Gira el objeto para capturar la base, o termina."
            case .capturing: return "Rodea el objeto despacio hasta completar la cúpula"
            case .finishing: return "Guardando fotos…"
            default: return nil
            }
        }()
        if let text {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch stage {
        case .ready:
            Button("Detectar objeto") {
                _ = captureSession.startDetecting()
            }
            .buttonStyle(PrimaryCaptureButtonStyle())
        case .detecting:
            HStack(spacing: 16) {
                Button("Reiniciar caja") { captureSession.resetDetection() }
                    .buttonStyle(OverlayButtonStyle())
                Button("Empezar captura") { captureSession.startCapturing() }
                    .buttonStyle(PrimaryCaptureButtonStyle())
            }
        case .capturing:
            HStack(spacing: 16) {
                if passCompleted {
                    Button("Girar y seguir") {
                        captureSession.beginNewScanPassAfterFlip()
                        passCount += 1
                        passCompleted = false
                    }
                    .buttonStyle(OverlayButtonStyle())
                }
                Button("Terminar") { captureSession.finish() }
                    .buttonStyle(PrimaryCaptureButtonStyle())
            }
        case .failed:
            Button("Cerrar") { onCancelled() }
                .buttonStyle(PrimaryCaptureButtonStyle())
        default:
            EmptyView()
        }
    }
}

struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(configuration.isPressed ? 0.8 : 0.6))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

struct PrimaryCaptureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color.orange.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(.black)
            .clipShape(Capsule())
    }
}
