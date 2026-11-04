import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()

    @State private var objectName = ""
    @State private var selectedMode: ScanMode = .objectCapture
    @State private var pendingSession: CaptureSessionInfo?
    @State private var history: [CaptureSessionInfo] = []
    @State private var path: [CaptureSessionInfo] = []
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Nuevo escaneo") {
                    TextField("Nombre de la pieza (opcional)", text: $objectName)
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
                        startScan()
                    } label: {
                        Label("Iniciar \(selectedMode.title)", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                            .font(.title3.bold())
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(tips(for: selectedMode))
                }

                Section {
                    DisclosureGroup("Antes de escanear: para un resultado nítido") {
                        tip("sun.max", "Luz difusa y pareja (día nublado, ventana o dos lámparas con pantalla). Sin sombras duras.")
                        tip("square.on.square.dashed", "Fondo que contraste con la pieza y sin dibujos.")
                        tip("sparkles", "Piezas brillantes, negras o transparentes: spray de escaneo mate (o talco). Con luz y lente polarizadas cruzadas los reflejos desaparecen.")
                        tip("scope", "Modo enfoque: toca la pieza para fijar el enfoque, o ajusta la caja en Objeto Pro para que solo la envuelva a ella.")
                        tip("arrow.triangle.2.circlepath", "¿Plato giratorio? Úsalo con Fotos 48 MP → Auto (iPhone fijo en trípode). En Objeto Pro no: ahí la pieza va quieta y tú caminas alrededor.")
                        tip("desktopcomputer", "Máxima calidad: reconstruye en el Mac (detalle Full); completa las partes que faltan y deja la pieza cerrada y a escala real.")
                    }
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
        .alert("No se pudo iniciar", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if alertMessage == Self.cameraDeniedMessage {
                Button("Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private static let cameraDeniedMessage =
        "ScanForge no tiene permiso para usar la cámara. Actívalo en Ajustes → ScanForge Pro → Cámara."

    /// Antes el botón quedaba desactivado sin avisar (nombre vacío o sin permiso de cámara)
    /// y parecía que no hacía nada. Ahora usa un nombre automático y explica cualquier fallo.
    private func startScan() {
        guard coordinator.capabilities.supports(selectedMode) else {
            alertMessage = "\(selectedMode.title) no está disponible en este dispositivo."
            return
        }
        var name = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "objeto-" + Date().formatted(.dateTime.day().month(.twoDigits).hour().minute())
            objectName = name
        }
        let mode = selectedMode
        let open = { pendingSession = coordinator.beginSession(objectName: name, mode: mode) }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            open()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { open() } else { alertMessage = Self.cameraDeniedMessage }
                }
            }
        default:
            alertMessage = Self.cameraDeniedMessage
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
                    HStack(spacing: 6) {
                        Text(mode.title).font(.headline).foregroundStyle(supported ? .primary : .secondary)
                        if let badge = mode.badge, supported {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
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

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: icon).foregroundStyle(.orange)
        }
    }

    private func tips(for mode: ScanMode) -> String {
        switch mode {
        case .objectCapture:
            return "La pieza quieta sobre una mesa y TÚ caminas alrededor (no uses plato giratorio aquí). Mucha luz difusa, fondo que contraste, 2–3 vueltas a distintas alturas y luego «Girar y seguir» para la base. Mínimo 30 fotos. Objetos de 5 cm a 2 m."
        case .lidarFusion:
            return "Toca el objeto para fijar la zona, luego rodéalo. Ideal para muebles, piezas grandes, personas y espacios. Precisión ~2–5 mm."
        case .trueDepthMicro:
            return "Usa un soporte y una plataforma giratoria a 20–40 cm de la cámara frontal. Superficies mates; evita negro brillante, cromo y vidrio (o aplica spray de escaneo)."
        case .manualPhotos:
            return "Ideal con plato giratorio: iPhone fijo en trípode, elige «Auto» y gira la pieza ~15° por foto en 3 alturas. Toca la pieza para fijar el enfoque. Luego «Máxima calidad: procesar en el Mac»."
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
