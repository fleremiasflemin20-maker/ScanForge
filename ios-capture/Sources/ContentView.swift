import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()

    @State private var objectName = ""
    @State private var selectedMode: ScanMode = .objectCapture
    @State private var pendingSession: CaptureSessionInfo?
    @State private var history: [CaptureSessionInfo] = []
    @State private var path: [CaptureSessionInfo] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Nuevo escaneo") {
                    TextField("Nombre del objeto (p.ej. jarron-001)", text: $objectName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Modo de escaneo") {
                    ForEach(ScanMode.allCases) { mode in
                        modeRow(mode)
                    }
                }

                Section {
                    Button {
                        pendingSession = coordinator.beginSession(objectName: objectName, mode: selectedMode)
                    } label: {
                        Label("Iniciar \(selectedMode.title)", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(objectName.trimmingCharacters(in: .whitespaces).isEmpty
                              || !coordinator.capabilities.supports(selectedMode))
                } footer: {
                    Text(tips(for: selectedMode))
                }

                if !history.isEmpty {
                    Section("Escaneos") {
                        ForEach(history) { session in
                            NavigationLink(value: session) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.objectName)
                                    Text("\(session.mode.title) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("ScanForge Pro")
            .navigationDestination(for: CaptureSessionInfo.self) { session in
                ResultView(session: session)
            }
            .onAppear(perform: reloadHistory)
        }
        .tint(.orange)
        .fullScreenCover(item: $pendingSession) { session in
            captureView(for: session)
        }
    }

    private func modeRow(_ mode: ScanMode) -> some View {
        let supported = coordinator.capabilities.supports(mode)
        return Button {
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(supported ? .orange : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline).foregroundStyle(supported ? .primary : .secondary)
                    Text(supported ? mode.subtitle : "No disponible en este dispositivo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedMode == mode {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported)
    }

    private func tips(for mode: ScanMode) -> String {
        switch mode {
        case .objectCapture:
            return "Luz difusa y uniforme, fondo que contraste. Haz 2–3 pasadas a distintas alturas y gira el objeto para capturar la base. Objetos de 5 cm a 2 m."
        case .lidarFusion:
            return "Toca el objeto para fijar la zona, luego rodéalo. Ideal para muebles, piezas grandes, personas y espacios. Precisión ~2–5 mm."
        case .trueDepthMicro:
            return "Usa un soporte y una plataforma giratoria a 20–40 cm de la cámara frontal. Superficies mates; evita negro brillante, cromo y vidrio (o aplica spray de escaneo)."
        case .manualPhotos:
            return "Rodea el objeto en 3 alturas (12 fotos por altura). Luego sube la carpeta al Mac para reconstruir."
        }
    }

    @ViewBuilder
    private func captureView(for session: CaptureSessionInfo) -> some View {
        switch session.mode {
        case .objectCapture:
            if #available(iOS 17.0, *) {
                LiDARCaptureView(
                    sessionInfo: session,
                    onFinished: finishCapture,
                    onCancelled: cancelCapture
                )
            }
        case .lidarFusion:
            LiDARFusionView(sessionInfo: session, onFinished: finishCapture, onCancelled: cancelCapture)
        case .trueDepthMicro:
            TrueDepthScanView(sessionInfo: session, onFinished: finishCapture, onCancelled: cancelCapture)
        case .manualPhotos:
            ManualCaptureView(sessionInfo: session, onFinished: finishCapture, onCancelled: cancelCapture)
        }
    }

    private func finishCapture(_ session: CaptureSessionInfo) {
        CaptureExporter.finalize(session)
        coordinator.endSession()
        pendingSession = nil
        reloadHistory()
        // Abre el resultado directamente (para Object Capture: botón de reconstruir).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            path = [session]
        }
    }

    private func cancelCapture() {
        if let session = pendingSession, CaptureExporter.allFiles(in: session.folderURL).isEmpty {
            try? FileManager.default.removeItem(at: session.folderURL)
        }
        coordinator.endSession()
        pendingSession = nil
    }

    private func reloadHistory() {
        history = CaptureSessionInfo.loadAll()
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: history[index].folderURL)
        }
        history.remove(atOffsets: offsets)
    }
}

#Preview {
    ContentView()
}
