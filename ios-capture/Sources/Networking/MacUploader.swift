import Foundation
import Network

/// Fase 3: descubre un receptor ScanForge en la red local vía Bonjour
/// (`_scanforge._tcp`, ver `scripts/receive_uploads.py`) y le sube la carpeta de
/// captura completa con un protocolo simple de longitud-prefijada sobre TCP:
///
///   [4 bytes BE: largo del header JSON] [header JSON: {"session": str, "fileCount": int}]
///   por cada archivo:
///     [4 bytes BE: largo del nombre] [nombre UTF8]
///     [8 bytes BE: largo del contenido] [bytes del archivo]
@MainActor
final class MacUploader: NSObject, ObservableObject {
    enum UploadState: Equatable {
        case idle
        case searching
        case uploading(fileIndex: Int, totalFiles: Int)
        case finished
        case failed(String)
    }

    @Published private(set) var state: UploadState = .idle

    private var browser: NWBrowser?
    private var connection: NWConnection?

    func upload(session: CaptureSessionInfo, timeout: TimeInterval = 15) {
        state = .searching
        CaptureExporter.finalize(session)

        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_scanforge._tcp", domain: nil), using: parameters)
        self.browser = browser

        var didConnect = false

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !didConnect, let first = results.first else { return }
            didConnect = true
            browser.cancel()
            MainActor.assumeIsolated {
                self.connect(to: first.endpoint, session: session)
            }
        }

        browser.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !didConnect else { return }
            browser.cancel()
            MainActor.assumeIsolated { self.state = .failed("No se encontró ningún Mac con ScanForge escuchando en la red local.") }
        }
    }

    private func connect(to endpoint: NWEndpoint, session: CaptureSessionInfo) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] connState in
            guard let self else { return }
            switch connState {
            case .ready:
                Task { @MainActor in self.sendSession(session, over: connection) }
            case .failed(let error):
                Task { @MainActor in self.state = .failed(error.localizedDescription) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func sendSession(_ session: CaptureSessionInfo, over connection: NWConnection) {
        let files = CaptureExporter.allFiles(in: session.folderURL)
        guard !files.isEmpty else {
            state = .failed("La sesión no tiene archivos para subir.")
            return
        }

        let header: [String: Any] = ["session": session.objectName, "fileCount": files.count]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else {
            state = .failed("No se pudo construir la cabecera de subida.")
            return
        }

        var payload = Data()
        payload.append(bigEndianUInt32(UInt32(headerData.count)))
        payload.append(headerData)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.state = .failed(error.localizedDescription) }
                return
            }
            Task { @MainActor in self.sendFiles(files, index: 0, over: connection) }
        })
    }

    private func sendFiles(_ files: [URL], index: Int, over connection: NWConnection) {
        guard index < files.count else {
            state = .finished
            connection.cancel()
            return
        }
        state = .uploading(fileIndex: index + 1, totalFiles: files.count)

        let fileURL = files[index]
        guard let fileData = try? Data(contentsOf: fileURL) else {
            // Si un archivo falla, lo saltamos y seguimos con el resto.
            sendFiles(files, index: index + 1, over: connection)
            return
        }

        let nameData = Array(fileURL.lastPathComponent.utf8)
        var payload = Data()
        payload.append(bigEndianUInt32(UInt32(nameData.count)))
        payload.append(Data(nameData))
        payload.append(bigEndianUInt64(UInt64(fileData.count)))
        payload.append(fileData)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.state = .failed(error.localizedDescription) }
                return
            }
            Task { @MainActor in self.sendFiles(files, index: index + 1, over: connection) }
        })
    }

    private func bigEndianUInt32(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private func bigEndianUInt64(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }
}
