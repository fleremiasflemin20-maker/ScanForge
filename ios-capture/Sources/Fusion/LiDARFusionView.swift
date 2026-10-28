import ARKit
import RealityKit
import SwiftUI

/// UI del modo LiDAR Fusión: cámara AR con la malla LiDAR superpuesta (cobertura), una
/// esfera que delimita la zona de escaneo y una vista 3D en vivo de la nube fusionada.
struct LiDARFusionView: View {
    let sessionInfo: CaptureSessionInfo
    let onFinished: (CaptureSessionInfo) -> Void
    let onCancelled: () -> Void

    @StateObject private var scanner = LiDARFusionScanner()
    @State private var preview: VoxelCloud.Snapshot?
    @State private var voxelMillimeters: Double = 3
    @State private var maxDepth: Double = 1.5
    @State private var radius: Double = 0.4
    @State private var isExporting = false
    @State private var errorMessage: String?

    private let previewTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ARScanContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                HStack {
                    Spacer()
                    PointCloudPreview(snapshot: preview, pointSize: 2)
                        .frame(width: 150, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3)))
                        .opacity(scanner.pointCount > 0 ? 1 : 0)
                }
                .padding(.horizontal)
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .padding(8)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                hint
                controlPanel
            }
        }
        .onAppear {
            scanner.settings.voxelSize = Float(voxelMillimeters / 1000)
            scanner.run()
        }
        .onDisappear { scanner.pause() }
        .onReceive(previewTimer) { _ in
            guard scanner.isScanning else { return }
            scanner.previewSnapshot { preview = $0 }
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancelar") {
                scanner.pause()
                onCancelled()
            }
            .buttonStyle(OverlayButtonStyle())
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(scanner.pointCount.formatted()) puntos")
                    .font(.footnote.monospacedDigit().bold())
                trackingLabel
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var trackingLabel: some View {
        switch scanner.tracking {
        case .good:
            Label("Seguimiento OK", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .limited(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow)
        case .lost:
            Label("Seguimiento perdido", systemImage: "xmark.octagon.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var hint: some View {
        let text = scanner.regionCenter == nil
            ? "Toca el objeto en pantalla para fijar la zona de escaneo"
            : (scanner.isScanning
               ? "Rodea el objeto despacio, a 30–60 cm. Las zonas sin malla aún no están cubiertas."
               : "Ajusta el radio y pulsa Escanear")
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if !scanner.isScanning && scanner.pointCount == 0 {
                HStack {
                    Text("Resolución")
                    Picker("Resolución", selection: $voxelMillimeters) {
                        Text("2 mm").tag(2.0)
                        Text("3 mm").tag(3.0)
                        Text("5 mm").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: voxelMillimeters) { _, value in
                        scanner.settings.voxelSize = Float(value / 1000)
                        scanner.run()
                    }
                }
            }
            if scanner.regionCenter != nil {
                HStack {
                    Text("Radio \(Int(radius * 100)) cm").font(.footnote.monospacedDigit()).frame(width: 90, alignment: .leading)
                    Slider(value: $radius, in: 0.1...1.5)
                        .onChange(of: radius) { _, value in
                            scanner.updateRegion(center: scanner.regionCenter, radius: Float(value))
                        }
                }
            }
            HStack {
                Text("Distancia máx. \(String(format: "%.1f", maxDepth)) m").font(.footnote.monospacedDigit()).frame(width: 130, alignment: .leading)
                Slider(value: $maxDepth, in: 0.4...4)
                    .onChange(of: maxDepth) { _, value in scanner.settings.maxDepth = Float(value) }
            }

            HStack(spacing: 14) {
                Button("Reiniciar") {
                    scanner.reset()
                    preview = nil
                }
                .buttonStyle(OverlayButtonStyle())

                Button(scanner.isScanning ? "Pausa" : "Escanear") {
                    scanner.setScanning(!scanner.isScanning)
                }
                .buttonStyle(PrimaryCaptureButtonStyle())

                Button(isExporting ? "Guardando…" : "Terminar") { finish() }
                    .buttonStyle(OverlayButtonStyle())
                    .disabled(scanner.pointCount == 0 || isExporting)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 16)
    }

    private func finish() {
        scanner.setScanning(false)
        isExporting = true
        scanner.export(to: sessionInfo.exportFolderURL, baseName: sessionInfo.safeBaseName) { result in
            isExporting = false
            switch result {
            case .success:
                scanner.pause()
                onFinished(sessionInfo)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// ARView de RealityKit compartiendo la ARSession del escáner. Muestra la malla LiDAR
/// (mapa de cobertura) y gestiona el toque para fijar el centro de la zona de escaneo.
private struct ARScanContainer: UIViewRepresentable {
    @ObservedObject var scanner: LiDARFusionScanner

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = scanner.session
        view.debugOptions.insert(.showSceneUnderstanding)
        view.renderOptions.insert(.disableMotionBlur)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.updateRegionMarker(center: scanner.regionCenter, radius: scanner.regionRadius)
    }

    func makeCoordinator() -> Coordinator { Coordinator(scanner: scanner) }

    final class Coordinator: NSObject {
        let scanner: LiDARFusionScanner
        weak var view: ARView?
        private var markerAnchor: AnchorEntity?
        private var markerRadius: Float = 0

        init(scanner: LiDARFusionScanner) { self.scanner = scanner }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            guard let hit = view.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first else { return }
            let t = hit.worldTransform.columns.3
            scanner.updateRegion(center: SIMD3<Float>(t.x, t.y, t.z), radius: scanner.regionRadius)
        }

        func updateRegionMarker(center: SIMD3<Float>?, radius: Float) {
            guard let view else { return }
            guard let center else {
                markerAnchor?.removeFromParent()
                markerAnchor = nil
                return
            }
            if markerAnchor == nil || abs(markerRadius - radius) > 0.005 {
                markerAnchor?.removeFromParent()
                let anchor = AnchorEntity(world: center)
                let material = SimpleMaterial(color: UIColor.orange.withAlphaComponent(0.12), isMetallic: false)
                let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
                let dot = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [SimpleMaterial(color: .orange, isMetallic: false)])
                anchor.addChild(sphere)
                anchor.addChild(dot)
                view.scene.addAnchor(anchor)
                markerAnchor = anchor
                markerRadius = radius
            } else {
                markerAnchor?.position = center
            }
        }
    }
}
