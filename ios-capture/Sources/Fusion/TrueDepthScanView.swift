import AVFoundation
import SwiftUI
import UIKit

/// UI del modo Micro TrueDepth. Pensado para usarse con el iPhone fijo (soporte o
/// apoyado) mirando al objeto sobre una plataforma giratoria: la pantalla queda hacia
/// ti, así ves en vivo cómo se construye el modelo mientras giras la plataforma.
struct TrueDepthScanView: View {
    let sessionInfo: CaptureSessionInfo
    let onFinished: (CaptureSessionInfo) -> Void
    let onCancelled: () -> Void

    @StateObject private var scanner = TrueDepthScanner()
    @State private var preview: VoxelCloud.Snapshot?
    @State private var turntable = true
    @State private var resolution: Double = 1
    @State private var maxDepthCM: Double = 45
    @State private var isExporting = false
    @State private var exportError: String?

    private let previewTimer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PointCloudPreview(snapshot: preview, pointSize: 2.5)
                    .ignoresSafeArea(edges: .top)

                CameraPreview(session: scanner.captureSession)
                    .frame(width: 110, height: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(trackingColor, lineWidth: 3))
                    .padding()
                    .padding(.top, 44)

                HStack {
                    Spacer()
                    statusBadge
                }
                .padding()
                .padding(.top, 44)
            }

            controls
        }
        .background(Color(white: 0.07))
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onReceive(previewTimer) { _ in
            guard scanner.isScanning else { return }
            scanner.previewSnapshot { preview = $0 }
        }
        .onChange(of: scanner.tracking) { _, state in
            if state == .lost {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private var trackingColor: Color {
        switch scanner.tracking {
        case .idle: return .white.opacity(0.4)
        case .tracking: return .green
        case .lost: return .red
        }
    }

    private var statusBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(scanner.pointCount.formatted()) puntos").font(.footnote.monospacedDigit().bold())
            Text(String(format: "%.0f fps", scanner.framesPerSecond)).font(.caption2.monospacedDigit())
            switch scanner.tracking {
            case .idle: Text("En espera").font(.caption2)
            case .tracking: Text("Siguiendo").font(.caption2).foregroundStyle(.green)
            case .lost: Text("Perdido: vuelve atrás despacio").font(.caption2).foregroundStyle(.red)
            }
            if turntable {
                Text(scanner.planeDetected ? "Plataforma detectada" : "Buscando plataforma…")
                    .font(.caption2)
                    .foregroundStyle(scanner.planeDetected ? .green : .yellow)
            }
        }
        .padding(10)
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let error = scanner.errorMessage ?? exportError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !scanner.isScanning && scanner.pointCount == 0 {
                Toggle("Plataforma giratoria (iPhone quieto)", isOn: $turntable)
                    .onChange(of: turntable) { _, value in scanner.settings.turntableMode = value }
                HStack {
                    Text("Resolución")
                    Picker("Resolución", selection: $resolution) {
                        Text("0.5 mm").tag(0.5)
                        Text("1 mm").tag(1.0)
                        Text("2 mm").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: resolution) { _, value in scanner.settings.voxelSize = Float(value / 1000) }
                }
                HStack {
                    Text("Distancia máx. \(Int(maxDepthCM)) cm").font(.footnote.monospacedDigit())
                    Slider(value: $maxDepthCM, in: 20...70)
                        .onChange(of: maxDepthCM) { _, value in scanner.settings.maxDepth = Float(value / 100) }
                }
                Text("Coloca el objeto a 20–40 cm de la cámara frontal. Gira la plataforma unos 20° por segundo; si el borde se pone rojo, retrocede un poco.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Button("Cancelar") {
                    scanner.stop()
                    onCancelled()
                }
                .buttonStyle(OverlayButtonStyle())

                Button(scanner.isScanning ? "Pausa" : "Escanear") {
                    scanner.setScanning(!scanner.isScanning)
                }
                .buttonStyle(PrimaryCaptureButtonStyle())

                Button("Reiniciar") {
                    scanner.reset()
                    preview = nil
                }
                .buttonStyle(OverlayButtonStyle())

                Button(isExporting ? "…" : "Terminar") { finish() }
                    .buttonStyle(OverlayButtonStyle())
                    .disabled(scanner.pointCount == 0 || isExporting)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func finish() {
        scanner.setScanning(false)
        isExporting = true
        scanner.export(to: sessionInfo.exportFolderURL, baseName: sessionInfo.safeBaseName) { result in
            isExporting = false
            switch result {
            case .success:
                scanner.stop()
                onFinished(sessionInfo)
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }
}
