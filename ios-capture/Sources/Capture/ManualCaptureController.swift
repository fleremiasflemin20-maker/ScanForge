import AVFoundation
import Foundation
import UIKit

/// Controla la cámara con AVFoundation para el modo manual (iPhones sin LiDAR).
/// Guía al usuario para rodear el objeto en 3 alturas y lleva la cuenta de fotos.
@MainActor
final class ManualCaptureController: NSObject, ObservableObject {
    @Published var phase: CapturePhase = .low
    @Published var photosInCurrentPhase = 0
    @Published var totalPhotos = 0
    @Published var isSessionRunning = false
    @Published var lastError: String?

    /// Fotos sugeridas por altura para lograr una buena cobertura angular (~cada 30°).
    let suggestedPhotosPerPhase = 12

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.scanforge.capture.session")

    private var outputFolder: URL?

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
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
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
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            Task { @MainActor in self?.isSessionRunning = false }
        }
    }

    /// Captura una foto y la guarda en la carpeta de la sesión con un nombre secuencial.
    /// Avanza automáticamente de altura cuando se alcanza el número sugerido de fotos.
    func capturePhoto() {
        guard let outputFolder else { return }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off

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

        let filename = String(format: "%@-%03d.jpg", pending.phase.fileTag, pending.index)
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
        }
    }
}

extension CapturePhase {
    var fileTag: String {
        switch self {
        case .low: return "low"
        case .mid: return "mid"
        case .high: return "high"
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
