import AVFoundation
import SwiftUI

/// UI de captura manual (sin LiDAR): vista previa de cámara + guía de 3 alturas +
/// contador de fotos + botón de disparo.
struct ManualCaptureView: View {
    let sessionInfo: CaptureSessionInfo
    let onFinished: (CaptureSessionInfo) -> Void
    let onCancelled: () -> Void

    @StateObject private var controller = ManualCaptureController()

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            heightGuideOverlay

            VStack {
                topBar
                Spacer()
                if let error = controller.lastError {
                    Text(error)
                        .padding(8)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                guidanceCard
                shutterBar
            }
        }
        .onAppear {
            controller.configure(outputFolder: sessionInfo.folderURL)
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancelar") {
                controller.stop()
                onCancelled()
            }
            .padding()
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding()
            Spacer()
            Text("\(controller.totalPhotos) fotos")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding()
        }
    }

    /// Marcas visuales simples en el borde de la pantalla indicando a qué altura
    /// relativa del objeto debe apuntar la cámara en esta fase.
    private var heightGuideOverlay: some View {
        GeometryReader { proxy in
            let y: CGFloat
            switch controller.phase {
            case .low: y = proxy.size.height * 0.75
            case .mid: y = proxy.size.height * 0.5
            case .high: y = proxy.size.height * 0.25
            }
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(height: 2)
                .position(x: proxy.size.width / 2, y: y)
        }
        .allowsHitTesting(false)
    }

    private var guidanceCard: some View {
        VStack(spacing: 4) {
            Text("Rodea el objeto a \(controller.phase.label)")
                .font(.headline)
            Text("\(controller.photosInCurrentPhase)/\(controller.suggestedPhotosPerPhase) fotos en esta altura · gira ~30° entre cada foto")
                .font(.caption)
        }
        .padding()
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var shutterBar: some View {
        HStack(spacing: 24) {
            if controller.phase != .low || controller.photosInCurrentPhase > 0 {
                Button("Terminar") {
                    controller.stop()
                    onFinished(sessionInfo)
                }
                .padding()
                .background(.white)
                .clipShape(Capsule())
            }

            Button {
                controller.capturePhoto()
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 2))
            }
        }
        .padding(.bottom, 32)
    }
}

/// Puente UIKit para mostrar el AVCaptureVideoPreviewLayer dentro de SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
