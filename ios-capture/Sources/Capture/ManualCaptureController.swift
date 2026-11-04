import AVFoundation
import Foundation
import ImageIO
import UIKit

/// Controla la cámara con AVFoundation para el modo Fotos 48 MP.
/// Guía al usuario para rodear el objeto en 3 alturas y lleva la cuenta de fotos.
///
/// Igual que en un rig de fotogrametría profesional:
/// - **Modo enfoque**: al tocar la pieza se fijan enfoque, exposición y balance de
///   blancos, así todas las fotos tienen la misma nitidez y color.
/// - **Control de nitidez**: cada foto se mide (varianza del laplaciano) y las
///   movidas/desenfocadas se descartan.
/// - **Plataforma giratoria**: disparo automático a intervalos con el iPhone fijo.
@MainActor
final class ManualCaptureController: NSObject, ObservableObject {
    @Published var phase: CapturePhase = .low
    @Published var photosInCurrentPhase = 0
    @Published var totalPhotos = 0
    @Published var isSessionRunning = false
    @Published var lastError: String?
    @Published var isLocked = false
    @Published var lockPoint: CGPoint?
    @Published var lastNotice: String?
    @Published var autoInterval: TimeInterval?
    @Published private(set) var autoCountdown = 0

    /// Fotos sugeridas por altura: cada ~30° a mano, cada 10° en plato giratorio
    /// (36 por vuelta: el óptimo de OpenScan está en 150–300 fotos en total).
    var suggestedPhotosPerPhase: Int { autoInterval == nil ? 12 : 36 }

    var phaseNumber: Int {
        switch phase {
        case .low: return 1
        case .mid: return 2
        case .high: return 3
        case .flip: return 4
        }
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.scanforge.capture.session")

    private var outputFolder: URL?
    private var device: AVCaptureDevice?
    private var sharpnessHistory: [Double] = []
    private var autoTimer: Timer?
    private var nextAutoShot = Date()

    func configure(outputFolder: URL) {
        self.outputFolder = outputFolder
        sessionQueue.async { [weak self] in
            self?.configureSessionIfNeeded()
        }
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            Task { @MainActor in self.lastError = "No se encontró la cámara trasera." }
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }
        Task { @MainActor in self.device = device }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Resolución completa del sensor (48 MP en el 17 Pro): más detalle para la
            // fotogrametría, igual que las cámaras de textura de los escáneres dedicados.
            if let largest = device.activeFormat.supportedMaxPhotoDimensions
                .max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photoOutput.maxPhotoDimensions = largest
            }
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        session.commitConfiguration()
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            self.session.startRunning()
            Task { @MainActor in self.isSessionRunning = true }
        }
    }

    func stop() {
        setAutoCapture(nil)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            Task { @MainActor in self?.isSessionRunning = false }
        }
    }

    // MARK: Modo enfoque

    /// Enfoca y expone en `devicePoint` (0…1, coordenadas del sensor) y lo deja fijo,
    /// junto con el balance de blancos. `viewPoint` es solo para dibujar el marcador.
    func focusAndLock(devicePoint: CGPoint, viewPoint: CGPoint) {
        guard let device else { return }
        lockPoint = viewPoint
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint }
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                device.unlockForConfiguration()
            } catch {
                return
            }
            // Deja que enfoque/exponga y después bloquea todo.
            Thread.sleep(forTimeInterval: 0.8)
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                Task { @MainActor in
                    self.isLocked = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {}
        }
    }

    func unlock() {
        guard let device else { return }
        isLocked = false
        lockPoint = nil
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: Plataforma giratoria

    /// `interval` nil = disparo manual.
    func setAutoCapture(_ interval: TimeInterval?) {
        autoTimer?.invalidate()
        autoTimer = nil
        autoInterval = interval
        guard let interval else { return }
        nextAutoShot = Date().addingTimeInterval(interval)
        autoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAutoCapture() }
        }
    }

    private func tickAutoCapture() {
        guard let interval = autoInterval else { return }
        let remaining = nextAutoShot.timeIntervalSinceNow
        autoCountdown = max(Int(remaining.rounded(.up)), 0)
        if remaining <= 0 {
            capturePhoto()
            nextAutoShot = Date().addingTimeInterval(interval)
        }
    }

    /// Captura una foto y la guarda en la carpeta de la sesión con un nombre secuencial.
    /// Avanza automáticamente de altura cuando se alcanza el número sugerido de fotos.
    func capturePhoto() {
        guard let outputFolder, pendingCapture == nil else { return }

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.flashMode = .off
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality

        let currentIndex = totalPhotos
        let currentPhase = phase

        photoOutput.capturePhoto(with: settings, delegate: self)
        pendingCapture = PendingCapture(index: currentIndex, phase: currentPhase, folder: outputFolder)
    }

    private struct PendingCapture {
        let index: Int
        let phase: CapturePhase
        let folder: URL
    }
    private var pendingCapture: PendingCapture?

    fileprivate func handleCapturedPhoto(data: Data?) {
        guard let pending = pendingCapture, let data else { return }
        pendingCapture = nil

        // Control de nitidez: comparamos con la mediana de las fotos aceptadas (la
        // nitidez absoluta depende del objeto; una foto movida cae muy por debajo).
        if let sharpness = Self.sharpness(of: data) {
            let sorted = sharpnessHistory.sorted()
            if sorted.count >= 3, sharpness < sorted[sorted.count / 2] * 0.45 {
                lastNotice = "Foto movida o desenfocada: descartada. Repite esa posición."
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            sharpnessHistory.append(sharpness)
        }
        lastNotice = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let filename = String(format: "%@-%03d.heic", pending.phase.fileTag, pending.index)
        let fileURL = pending.folder.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
        } catch {
            lastError = "No se pudo guardar la foto: \(error.localizedDescription)"
            return
        }

        totalPhotos += 1
        photosInCurrentPhase += 1

        if photosInCurrentPhase >= suggestedPhotosPerPhase, let next = phase.next {
            phase = next
            photosInCurrentPhase = 0
            // Cambio de anillo: el usuario tiene que mover la cámara (o voltear la pieza),
            // así que el disparo automático se pausa hasta que pulse Auto otra vez.
            if autoInterval != nil { setAutoCapture(nil) }
            lastNotice = "Vuelta completa. \(next.instruction) Luego pulsa Auto otra vez."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if photosInCurrentPhase >= suggestedPhotosPerPhase, phase.next == nil {
            setAutoCapture(nil)
            lastNotice = "¡Captura completa! Pulsa Terminar."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

extension ManualCaptureController {
    /// Varianza del laplaciano sobre una miniatura de 640 px en gris: medida estándar
    /// de enfoque/desenfoque por movimiento.
    nonisolated static func sharpness(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let width = thumb.width, height = thumb.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0.0, sumSquares = 0.0, n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let lap = Double(gray[i - 1]) + Double(gray[i + 1]) + Double(gray[i - width])
                    + Double(gray[i + width]) - 4 * Double(gray[i])
                sum += lap
                sumSquares += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}

extension CapturePhase {
    var fileTag: String {
        switch self {
        case .low: return "low"
        case .mid: return "mid"
        case .high: return "high"
        case .flip: return "flip"
        }
    }
}

extension ManualCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            self.handleCapturedPhoto(data: data)
        }
    }
}
