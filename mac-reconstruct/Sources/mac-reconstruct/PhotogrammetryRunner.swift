import Foundation
import RealityKit

/// Enum de errores propios, con mensajes orientados a las causas más comunes de fallo
/// de PhotogrammetrySession: pocas fotos, poca superposición, imágenes borrosas, etc.
enum ReconstructError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case sessionCreationFailed(underlying: Error)
    case processingFailed(underlying: Error)
    case noOutputsProduced

    var description: String {
        switch self {
        case .unsupportedPlatform:
            return "Este equipo no soporta Object Capture (se necesita un Mac con Apple Silicon y macOS 14+)."
        case .sessionCreationFailed(let underlying):
            return "No se pudo crear la sesión de fotogrametría: \(underlying.localizedDescription)"
        case .processingFailed(let underlying):
            return "La reconstrucción falló: \(underlying.localizedDescription)"
        case .noOutputsProduced:
            return "La sesión terminó sin producir ningún archivo de salida."
        }
    }
}

@available(macOS 14.0, *)
final class PhotogrammetryRunner {
    private let input: URL
    private let outputDirectory: URL
    private let detail: PhotogrammetrySession.Request.Detail
    private let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity
    private let objectMaskingEnabled: Bool
    private let progress = ProgressReporter()
    private var startedLabels: Set<String> = []

    init(
        input: URL,
        outputDirectory: URL,
        detail: PhotogrammetrySession.Request.Detail,
        featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity,
        objectMaskingEnabled: Bool
    ) {
        self.input = input
        self.outputDirectory = outputDirectory
        self.detail = detail
        self.featureSensitivity = featureSensitivity
        self.objectMaskingEnabled = objectMaskingEnabled
    }

    func run() async throws {
        guard PhotogrammetrySession.isSupported else {
            throw ReconstructError.unsupportedPlatform
        }

        var configuration = PhotogrammetrySession.Configuration()
        configuration.featureSensitivity = featureSensitivity
        configuration.isObjectMaskingEnabled = objectMaskingEnabled
        configuration.sampleOrdering = .unordered

        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: input, configuration: configuration)
        } catch {
            throw ReconstructError.sessionCreationFailed(underlying: error)
        }

        let usdzURL = outputDirectory.appendingPathComponent("model.usdz")
        let objURL = outputDirectory.appendingPathComponent("model.obj")

        let requests: [PhotogrammetrySession.Request] = [
            .modelFile(url: usdzURL, detail: detail),
            .modelFile(url: objURL, detail: detail)
        ]

        var producedAny = false
        var caughtError: Error?

        let consumerTask = Task {
            for try await output in session.outputs {
                switch output {
                case .processingComplete:
                    progress.finishLine()
                    progress.info("Procesamiento completo.")

                case .requestProgress(let request, let fraction):
                    let label = describe(request)
                    if !startedLabels.contains(label) {
                        startedLabels.insert(label)
                        progress.startRequest(label: "Generando \(label)")
                    }
                    progress.update(fraction: fraction)

                case .requestProgressInfo:
                    // Información adicional de progreso; el porcentaje ya lo da .requestProgress.
                    break

                case .requestComplete(let request, let result):
                    progress.finishLine()
                    switch result {
                    case .modelFile(let url):
                        progress.info("✓ Generado: \(url.lastPathComponent)")
                        producedAny = true
                    @unknown default:
                        progress.info("✓ Solicitud completada: \(describe(request))")
                        producedAny = true
                    }

                case .requestError(let request, let error):
                    progress.warn("Falló \(describe(request)): \(error.localizedDescription)")
                    caughtError = error

                case .inputComplete:
                    progress.info("Todas las imágenes fueron leídas, procesando...")

                case .invalidSample(let id, let reason):
                    progress.warn("Imagen inválida (\(id)): \(reason)")

                case .skippedSample(let id):
                    progress.warn("Imagen omitida por baja calidad o poca superposición: \(id)")

                case .automaticDownsampling:
                    progress.warn("Se redujo automáticamente la resolución de entrada (memoria/GPU insuficiente para el detalle solicitado).")

                case .stitchingIncomplete:
                    progress.warn("El modelo no pudo unirse en una sola pieza continua: revisa que las fotos rodeen el objeto completo con suficiente solape.")

                case .processingCancelled:
                    progress.warn("Procesamiento cancelado.")

                @unknown default:
                    break
                }
            }
        }

        print("Etiquetas de progreso: preview=rápido/baja calidad, full=calidad de impresión, raw=máxima resolución (lento).")
        print("Iniciando procesamiento, esto puede tardar varios minutos según el detalle y el número de fotos...\n")

        do {
            try session.process(requests: requests)
        } catch {
            consumerTask.cancel()
            throw ReconstructError.processingFailed(underlying: error)
        }

        try await consumerTask.value

        if let caughtError {
            throw ReconstructError.processingFailed(underlying: caughtError)
        }
        guard producedAny else {
            throw ReconstructError.noOutputsProduced
        }

        print("\nListo. Archivos en: \(outputDirectory.path)")
    }

    private func describe(_ request: PhotogrammetrySession.Request) -> String {
        switch request {
        case .modelFile(let url, _):
            return url.lastPathComponent
        @unknown default:
            return "solicitud"
        }
    }
}
