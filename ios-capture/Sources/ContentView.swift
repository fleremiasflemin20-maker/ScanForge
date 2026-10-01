import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()
    @StateObject private var uploader = MacUploader()

    @State private var objectName = ""
    @State private var pendingSession: CaptureSessionInfo?
    @State private var completedSession: CaptureSessionInfo?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nuevo escaneo") {
                    TextField("Nombre del objeto (p.ej. jarron-001)", text: $objectName)
                        .autocorrectionDisabled()

                    Text(coordinator.mode == .lidarGuided
                         ? "Modo: captura guiada con LiDAR"
                         : "Modo: captura manual (sin LiDAR)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Iniciar captura") {
                        pendingSession = coordinator.beginSession(objectName: objectName)
                    }
                    .disabled(objectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let session = completedSession {
                    Section("Última sesión") {
                        Text(session.objectName)
                        Text("\(CaptureExporter.countPhotos(in: session.folderURL)) fotos guardadas")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        uploadStatusView

                        Button("Subir al Mac (red local)") {
                            uploader.upload(session: session)
                        }
                    }
                }
            }
            .navigationTitle("ScanForge")
        }
        .fullScreenCover(item: $pendingSession) { session in
            captureView(for: session)
        }
    }

    @ViewBuilder
    private func captureView(for session: CaptureSessionInfo) -> some View {
        if coordinator.mode == .lidarGuided, #available(iOS 17.0, *) {
            LiDARCaptureView(
                sessionInfo: session,
                onFinished: { finished in finishCapture(finished) },
                onCancelled: { pendingSession = nil }
            )
        } else {
            ManualCaptureView(
                sessionInfo: session,
                onFinished: { finished in finishCapture(finished) },
                onCancelled: { pendingSession = nil }
            )
        }
    }

    private func finishCapture(_ session: CaptureSessionInfo) {
        CaptureExporter.finalize(session)
        completedSession = session
        coordinator.endSession()
        pendingSession = nil
    }

    @ViewBuilder
    private var uploadStatusView: some View {
        switch uploader.state {
        case .idle:
            EmptyView()
        case .searching:
            Text("Buscando tu Mac en la red local...")
                .font(.footnote)
        case .uploading(let index, let total):
            Text("Subiendo \(index)/\(total)...")
                .font(.footnote)
        case .finished:
            Text("✓ Subida completa")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Text("✗ \(message)")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    ContentView()
}
