import AVFoundation
import AVKit
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
            CameraPreview(session: controller.session) { devicePoint, viewPoint in
                controller.focusAndLock(devicePoint: devicePoint, viewPoint: viewPoint)
            }
            .ignoresSafeArea()

            heightGuideOverlay
            focusMarker

            VStack {
                topBar
                focusBar
                autoPicker
                    .padding(.top, 6)
                Spacer()
                if let notice = controller.lastNotice {
                    Text(notice)
                        .font(.callout.weight(.semibold))
                        .padding(8)
                        .background(.orange.opacity(0.9))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
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
        .modifier(HardwareShutter { controller.capturePhoto() })
    }

    /// Cuadro amarillo donde se fijó el enfoque (modo enfoque).
    @ViewBuilder
    private var focusMarker: some View {
        if let point = controller.lockPoint {
            RoundedRectangle(cornerRadius: 6)
                .stroke(controller.isLocked ? Color.yellow : Color.white, lineWidth: 2)
                .frame(width: 84, height: 84)
                .position(point)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: controller.isLocked)
        }
    }

    private var focusBar: some View {
        HStack(spacing: 10) {
            if controller.isLocked {
                Label("Enfoque fijado en la pieza", systemImage: "lock.fill")
                    .font(.footnote.bold())
                Button("Soltar") { controller.unlock() }
                    .font(.footnote.bold())
                    .buttonStyle(.bordered)
                    .tint(.white)
            } else {
                Label("Toca la pieza para fijar enfoque y exposición", systemImage: "scope")
                    .font(.footnote.bold())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6))
        .foregroundStyle(controller.isLocked ? .yellow : .white)
        .clipShape(Capsule())
    }

    /// Selector Manual / plataforma giratoria (disparo automático).
    private var autoPicker: some View {
        let options: [(String, TimeInterval?)] = [("Manual", nil), ("Auto 2 s", 2), ("Auto 3 s", 3), ("Auto 5 s", 5)]
        return HStack(spacing: 6) {
            ForEach(options, id: \.0) { option in
                let selected = controller.autoInterval == option.1
                Button(option.0) { controller.setAutoCapture(option.1) }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selected ? Color.orange : Color.black.opacity(0.6))
                    .foregroundStyle(selected ? .black : .white)
                    .clipShape(Capsule())
            }
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
            let y = proxy.size.height * guideFraction(for: controller.phase)
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(height: 2)
                .position(x: proxy.size.width / 2, y: y)
        }
        .allowsHitTesting(false)
    }

    private func guideFraction(for phase: CapturePhase) -> CGFloat {
        switch phase {
        case .low: return 0.75
        case .mid: return 0.5
        case .high: return 0.25
        case .flip: return 0.5
        }
    }

    private var guidanceCard: some View {
        VStack(spacing: 4) {
            Text("Vuelta \(controller.phaseNumber)/4 · \(controller.phase.label)")
                .font(.headline)
            Text(controller.autoInterval == nil
                 ? "\(controller.photosInCurrentPhase)/\(controller.suggestedPhotosPerPhase) fotos en esta altura · gira ~30° entre cada foto"
                 : "\(controller.photosInCurrentPhase)/\(controller.suggestedPhotosPerPhase) · gira la plataforma ~15° · próxima foto en \(controller.autoCountdown) s")
                .font(.caption)
            Text("También disparas con los botones de volumen")
                .font(.caption2)
                .opacity(0.8)
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

/// Disparo con los botones de volumen o el Control de Cámara (iOS 18+): así no se
/// mueve el iPhone al pulsar la pantalla.
struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}

/// Puente UIKit para mostrar el AVCaptureVideoPreviewLayer dentro de SwiftUI.
/// `onTap` recibe el punto en coordenadas del sensor (0…1) y en la vista.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewUIView.handleTap(_:))))
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onTap = onTap
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
    var onTap: ((CGPoint, CGPoint) -> Void)?

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        onTap?(videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint), viewPoint)
    }
}
