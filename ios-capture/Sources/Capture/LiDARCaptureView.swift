import RealityKit
import SwiftUI

/// Envuelve `ObjectCaptureSession` + `ObjectCaptureView` (RealityKit, iOS 17+) para la
/// captura guiada en dispositivos con LiDAR: Apple se encarga de la UI de guía
/// (ángulos, "rodea el objeto", "dale la vuelta"), nosotros solo arrancamos la sesión
/// y reaccionamos a su estado para saber cuándo terminó.
@available(iOS 17.0, *)
struct LiDARCaptureView: View {
    let sessionInfo: CaptureSessionInfo
    let onFinished: (CaptureSessionInfo) -> Void
    let onCancelled: () -> Void

    @StateObject private var captureSession = ObjectCaptureSession()

    /// Proyección del estado a un Int simple: evita depender de si `CaptureState`
    /// conforma Equatable (tiene un caso `.failed(Error)` con asociado) para poder
    /// usar `.onChange(of:)`.
    private var stateTag: Int {
        switch captureSession.state {
        case .initializing: return 0
        case .ready: return 1
        case .detecting: return 2
        case .capturing: return 3
        case .finishing: return 4
        case .completed: return 5
        case .failed: return 6
        @unknown default: return -1
        }
    }

    private var showsReadyHint: Bool {
        switch captureSession.state {
        case .ready, .detecting: return true
        default: return false
        }
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
                    .padding()
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding()
                    Spacer()
                }
                Spacer()

                if showsReadyHint {
                    Text("Encuadra el objeto y espera a que se detecte")
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 40)
                }

                if captureSession.userCompletedScanPass {
                    Button("Girar objeto y continuar") {
                        captureSession.beginNewScanPassAfterFlip()
                    }
                    .padding()
                    .background(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            captureSession.start(imagesDirectory: sessionInfo.folderURL)
        }
        .onChange(of: stateTag) { _, _ in
            switch captureSession.state {
            case .completed:
                onFinished(sessionInfo)
            case .failed:
                onCancelled()
            default:
                break
            }
        }
    }
}
