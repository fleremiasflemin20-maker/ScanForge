import ArgumentParser
import Foundation
import RealityKit

@available(macOS 14.0, *)
struct ScanForgeReconstruct: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-reconstruct",
        abstract: "Reconstruye una malla 3D a partir de fotos usando PhotogrammetrySession (RealityKit).",
        discussion: """
        Lee una carpeta de imágenes (HEIC/JPG, con mapas de profundidad si los hay, capturadas por \
        ios-capture) y escribe un USDZ y un OBJ con la reconstrucción fotogramétrica.
        """
    )

    @Option(name: .long, help: "Carpeta con las imágenes de entrada.")
    var input: String

    @Option(name: .long, help: "Carpeta de salida donde se escriben model.usdz y model.obj.")
    var output: String

    @Option(name: .long, help: "Nivel de detalle: preview, reduced, medium, full, raw.")
    var detail: DetailArgument = .full

    @Option(name: .long, help: "Sensibilidad de detección de features: normal o high.")
    var featureSensitivity: FeatureSensitivityArgument = .normal

    @Flag(name: .long, help: "Activa el enmascarado de objeto (usa máscaras *_mask.HEIC junto a cada imagen si existen).")
    var objectMasking: Bool = false

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input, isDirectory: true)
        let outputDir = URL(fileURLWithPath: output, isDirectory: true)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("La carpeta de entrada no existe: \(inputURL.path)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let imageCount = try countCandidateImages(in: inputURL)
        print("mac-reconstruct")
        print("  entrada:   \(inputURL.path)  (\(imageCount) imágenes detectadas)")
        print("  salida:    \(outputDir.path)")
        print("  detalle:   \(detail.rawValue)")
        print("  features:  \(featureSensitivity.rawValue)")
        print("  masking:   \(objectMasking ? "activado" : "desactivado")")
        print("")

        if imageCount < 10 {
            print("⚠️  Aviso: solo hay \(imageCount) imágenes. PhotogrammetrySession suele necesitar al menos 20-40 fotos con buena superposición (>60-70%) para una reconstrucción fiable.")
        }

        let runner = PhotogrammetryRunner(
            input: inputURL,
            outputDirectory: outputDir,
            detail: detail.sessionDetail,
            featureSensitivity: featureSensitivity.sessionValue,
            objectMaskingEnabled: objectMasking
        )

        try await runner.run()
    }

    private func countCandidateImages(in url: URL) throws -> Int {
        let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "dng"]
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        return contents.filter { extensions.contains($0.pathExtension.lowercased()) }.count
    }
}

@available(macOS 14.0, *)
enum DetailArgument: String, ExpressibleByArgument, CaseIterable {
    case preview, reduced, medium, full, raw

    var sessionDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .preview: return .preview
        case .reduced: return .reduced
        case .medium: return .medium
        case .full: return .full
        case .raw: return .raw
        }
    }
}

@available(macOS 14.0, *)
enum FeatureSensitivityArgument: String, ExpressibleByArgument, CaseIterable {
    case normal, high

    var sessionValue: PhotogrammetrySession.Configuration.FeatureSensitivity {
        switch self {
        case .normal: return .normal
        case .high: return .high
        }
    }
}
