import QuickLook
import SwiftUI

/// Pantalla de resultado de una sesión: reconstrucción en el iPhone (Object Capture),
/// lista de archivos exportados, vista 3D, compartir (AirDrop, Archivos, Bambu Handy…)
/// y subida al Mac.
struct ResultView: View {
    let session: CaptureSessionInfo

    @StateObject private var reconstructor = OnDeviceReconstructor()
    @StateObject private var uploader = MacUploader()
    @State private var files: [URL] = []
    @State private var quickLookURL: URL?
    @State private var options = CaptureExporter.ScanOptions()
    @State private var longestText = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Modo", value: session.mode.title)
                LabeledContent("Fecha", value: session.createdAt.formatted(date: .abbreviated, time: .shortened))
                let photos = CaptureExporter.countPhotos(in: session.folderURL)
                if photos > 0 {
                    LabeledContent("Fotos", value: "\(photos)")
                }
            }

            if session.mode == .objectCapture {
                reconstructionSection
            }

            Section {
                HStack {
                    Text("Lado más largo")
                    Spacer()
                    TextField("mm (calibre)", text: $longestText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                    Text("mm").foregroundStyle(.secondary)
                }
                Toggle("Pieza mecánica (ranuras y encajes)", isOn: $options.mechanical)
            } header: {
                Text("Precisión para piezas técnicas")
            } footer: {
                Text("Mide con un calibre el lado más largo de la pieza: el Mac corrige la escala con esa medida (la mayor fuente de error). «Pieza mecánica» deja las caras planas exactas y las aristas vivas, sin redondear ranuras ni encajes. Se aplica al procesar en el Mac.")
            }

            Section("Modelos") {
                if files.isEmpty {
                    Text(session.mode == .manualPhotos
                         ? "Las fotos están listas para reconstruir en el Mac (mac-reconstruct)."
                         : "Todavía no hay modelos exportados.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: icon(for: url))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).font(.callout)
                            Text(description(for: url)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if url.pathExtension.lowercased() == "usdz" {
                            Button("Ver") { quickLookURL = url }
                                .buttonStyle(.bordered)
                        }
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if files.count > 1 {
                    ShareLink(items: files) {
                        Label("Compartir todo", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }

            Section {
                Button {
                    uploader.upload(session: session)
                } label: {
                    Label("Máxima calidad: procesar en el Mac", systemImage: "desktopcomputer")
                        .font(.headline)
                }
                uploadStatus
            } header: {
                Text("Mac")
            } footer: {
                Text("El Mac reconstruye con detalle Full (el iPhone solo permite detalle reducido), completa las zonas que no se vieron, cierra la malla y la deja a escala real lista para el slicer. En el Mac: scripts/receive_uploads.py --auto-process --open \"Bambu Studio\".\n\nSTL/OBJ salen en milímetros con Z arriba. También están en Archivos → En mi iPhone → ScanForge.")
            }
        }
        .navigationTitle(session.objectName)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($quickLookURL)
        .onAppear {
            reload()
            options = CaptureExporter.loadOptions(for: session)
            longestText = options.longestMM.map { String(format: "%g", $0) } ?? ""
        }
        .onChange(of: longestText) { _, text in
            options.longestMM = Double(text.replacingOccurrences(of: ",", with: "."))
        }
        .onChange(of: options) { _, newValue in
            CaptureExporter.saveOptions(newValue, for: session)
        }
    }

    @ViewBuilder
    private var reconstructionSection: some View {
        Section("Reconstrucción en el iPhone") {
            switch reconstructor.state {
            case .idle:
                Button {
                    reconstructor.reconstruct(session) { reload() }
                } label: {
                    Label(files.contains { $0.pathExtension == "usdz" } ? "Reconstruir de nuevo" : "Reconstruir modelo 3D",
                          systemImage: "cube.transparent")
                }
                .disabled(!OnDeviceReconstructor.isSupported)
                if !OnDeviceReconstructor.isSupported {
                    Text("Este dispositivo no reconstruye localmente: sube las fotos al Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .running(let progress):
                VStack(alignment: .leading) {
                    ProgressView(value: progress)
                    Text("Reconstruyendo… \(Int(progress * 100))% — mantén la app abierta")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancelar", role: .destructive) { reconstructor.cancel() }
            case .finished:
                Label("Modelo listo (USDZ + STL + OBJ)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Reintentar") { reconstructor.reconstruct(session) { reload() } }
            }
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch uploader.state {
        case .idle: EmptyView()
        case .searching: Text("Buscando tu Mac en la red local...").font(.footnote)
        case .uploading(let index, let total): ProgressView(value: Double(index), total: Double(total))
        case .finished: Text("✓ Subida completa").font(.footnote).foregroundStyle(.green)
        case .failed(let message): Text("✗ \(message)").font(.footnote).foregroundStyle(.red)
        }
    }

    private func reload() {
        CaptureExporter.finalize(session)
        files = CaptureExporter.exportedFiles(for: session)
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "usdz": return "cube.fill"
        case "stl": return "printer.fill"
        case "ply": return "aqi.medium"
        default: return "doc.fill"
        }
    }

    private func description(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        switch url.pathExtension.lowercased() {
        case "usdz": return "Modelo texturizado · \(sizeText)"
        case "stl": return "Para imprimir (mm) · \(sizeText)"
        case "obj": return "Malla (mm) · \(sizeText)"
        case "ply": return "Nube de puntos · \(sizeText)"
        default: return sizeText
        }
    }
}

extension CaptureSessionInfo {
    /// Reconstruye la info de una sesión guardada a partir de su `scanforge-session.json`.
    init?(restoringFrom folder: URL) {
        let metadataURL = folder.appendingPathComponent("scanforge-session.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(CaptureExporter.Metadata.self, from: data),
              let mode = ScanMode(rawValue: metadata.mode) else { return nil }
        self.id = UUID()
        self.objectName = metadata.objectName
        self.createdAt = metadata.createdAt
        self.mode = mode
        self.photoCount = metadata.photoCount
        self.folderURL = folder
    }

    static func loadAll() -> [CaptureSessionInfo] {
        let root = CaptureStorage.capturesRootURL
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return folders
            .compactMap { CaptureSessionInfo(restoringFrom: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
