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

    /// Se crea una sola vez en `.task` (no en el init de la vista, que SwiftUI repite).
    @State private var captureSession: ObjectCaptureSession?
    @State private var stage: Stage = .initializing
    @State private var passCompleted = false
    @State private var passCount = 1
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var shots = 0
    @State private var maxShots = 0
    @State private var feedback: Set<ObjectCaptureSession.Feedback> = []
    @State private var confirmFinish = false

    /// Por debajo de esto la reconstrucción suele fallar (Apple recomienda 30–100+).
    private let minimumShots = 30
    @State private var stalled = false

    /// Copia simple del estado de la sesión: evita depender de si `CaptureState` es
    /// Equatable (tiene `.failed(Error)`), y se actualiza desde `stateUpdates`.
    private enum Stage {
        case initializing, ready, detecting, capturing, finishing, completed, failed
    }

    var body: some View {
        ZStack {
            if let captureSession, stage != .failed, stage != .completed {
                ObjectCaptureView(session: captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button("Cancelar") {
                        captureSession?.cancel()
                        onCancelled()
                    }
                    .buttonStyle(OverlayButtonStyle())
                    Spacer()
                    if stage == .capturing {
                        Text("\(shots) fotos · pasada \(passCount)")
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

                feedbackBanner
                hint
                if stalled && stage == .initializing {
                    Button("Reintentar") { attempt += 1 }
                        .buttonStyle(PrimaryCaptureButtonStyle())
                        .padding(.bottom, 8)
                }
                controls
                    .padding(.bottom, 32)
            }
        }
        .task(id: attempt) {
            // Si en 8 s la sesión sigue "iniciando", ofrecemos reintentar.
            stalled = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if stage == .initializing { stalled = true }
            }
            if let old = captureSession {
                old.cancel()
                captureSession = nil
            }
            print("[ObjectCapture] intento \(attempt), isSupported=\(ObjectCaptureSession.isSupported), carpeta=\(sessionInfo.folderURL.path)")
            guard ObjectCaptureSession.isSupported else {
                stage = .failed
                errorMessage = "Objeto Pro necesita un iPhone con LiDAR."
                return
            }
            // La carpeta de imágenes debe existir y estar vacía.
            let fm = FileManager.default
            try? fm.createDirectory(at: sessionInfo.folderURL, withIntermediateDirectories: true)
            for leftover in (try? fm.contentsOfDirectory(at: sessionInfo.folderURL, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: leftover)
            }

            let session = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = sessionInfo.checkpointFolderURL
            configuration.isOverCaptureEnabled = true
            session.start(imagesDirectory: sessionInfo.folderURL, configuration: configuration)
            // `stateUpdates` solo emite cambios futuros: leemos el estado actual por si
            // la sesión ya pasó a .ready o falló al arrancar.
            print("[ObjectCapture] tras start: \(session.state)")
            apply(session.state)
            if stage != .failed { captureSession = session }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await state in session.stateUpdates { apply(state) }
                }
                // Respaldo: también leemos el estado directamente, por si `stateUpdates`
                // no emite (la sesión cambia pero la vista no se entera).
                group.addTask { @MainActor in
                    var last = ""
                    while !Task.isCancelled {
                        shots = session.numberOfShotsTaken
                        maxShots = session.maximumNumberOfInputImages
                        if session.feedback != feedback { feedback = session.feedback }
                        let current = String(describing: session.state)
                        if current != last {
                            last = current
                            print("[ObjectCapture] sondeo: \(current) tracking=\(session.cameraTracking) feedback=\(session.feedback)")
                            apply(session.state)
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                group.addTask { @MainActor in
                    for await completed in session.userCompletedScanPassUpdates { passCompleted = completed }
                }
            }
        }
    }

    private func apply(_ state: ObjectCaptureSession.CaptureState) {
        print("[ObjectCapture] estado: \(state)")
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

    /// Avisos de Apple traducidos: es lo que hace que una captura salga nítida o falle.
    @ViewBuilder
    private var feedbackBanner: some View {
        let messages = feedback.compactMap(Self.message(for:))
        if !messages.isEmpty, stage == .ready || stage == .detecting || stage == .capturing {
            VStack(spacing: 4) {
                ForEach(messages, id: \.self) { Text($0) }
            }
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(10)
            .background(Color.yellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private static func message(for feedback: ObjectCaptureSession.Feedback) -> String? {
        switch feedback {
        case .environmentLowLight: return "💡 Poca luz: enciende más luz o acércate a una ventana"
        case .environmentTooDark: return "🌑 Demasiado oscuro: así no se puede escanear"
        case .objectTooClose: return "↔️ Demasiado cerca: aléjate un poco"
        case .objectTooFar: return "↔️ Demasiado lejos: acércate a la pieza"
        case .movingTooFast: return "🐢 Más despacio"
        case .outOfFieldOfView: return "🎯 La pieza se sale de la imagen: céntrala"
        case .objectNotDetected: return "🎯 No veo la pieza: apunta a ella"
        case .objectNotFlippable: return "Esta pieza no conviene girarla: escanéala de pie"
        case .overCapturing: return nil
        @unknown default: return nil
        }
    }

    @ViewBuilder
    private var hint: some View {
        let text: String? = {
            switch stage {
            case .initializing:
                return stalled ? "El LiDAR no termina de arrancar. Mueve el iPhone despacio apuntando a la pieza, o pulsa Reintentar." : "Iniciando LiDAR…"
            case .ready: return "Modo enfoque: pon el punto blanco sobre la pieza y pulsa «Enfocar pieza»"
            case .detecting: return "Ajusta la caja para que envuelva SOLO la pieza (arrastra sus bordes). Lo de fuera se ignora."
            case .capturing where passCompleted:
                return "Pasada completa. Gira el objeto para capturar la base, o termina."
            case .capturing: return "Camina alrededor de la pieza despacio (no la gires a ella) hasta completar el anillo. \(shots)/\(minimumShots)+ fotos"
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
            Button("Enfocar pieza") {
                _ = captureSession?.startDetecting()
            }
            .buttonStyle(PrimaryCaptureButtonStyle())
        case .detecting:
            HStack(spacing: 16) {
                Button("Reiniciar caja") { captureSession?.resetDetection() }
                    .buttonStyle(OverlayButtonStyle())
                Button("Empezar captura") { captureSession?.startCapturing() }
                    .buttonStyle(PrimaryCaptureButtonStyle())
            }
        case .capturing:
            HStack(spacing: 16) {
                if passCompleted {
                    Button("Girar y seguir") {
                        captureSession?.beginNewScanPassAfterFlip()
                        passCount += 1
                        passCompleted = false
                    }
                    .buttonStyle(OverlayButtonStyle())
                }
                Button("Terminar") {
                    if shots < minimumShots { confirmFinish = true } else { captureSession?.finish() }
                }
                .buttonStyle(PrimaryCaptureButtonStyle())
                .confirmationDialog("Solo hay \(shots) fotos", isPresented: $confirmFinish, titleVisibility: .visible) {
                    Button("Seguir capturando", role: .cancel) {}
                    Button("Terminar igualmente") { captureSession?.finish() }
                } message: {
                    Text("Con menos de \(minimumShots) fotos la reconstrucción suele fallar. Rodea la pieza completa (y gírala para la base).")
                }
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
