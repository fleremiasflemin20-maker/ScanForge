import ARKit
import Foundation
import simd

/// Escáner en tiempo real con el LiDAR trasero.
///
/// Equivale al "seguimiento híbrido" de los escáneres de mano: ARKit da la pose del
/// iPhone por fusión visual-inercial (cámara + IMU, sin marcadores), y cada fotograma
/// de profundidad LiDAR (con su mapa de confianza) se proyecta al mundo y se fusiona en
/// una rejilla de vóxeles. En paralelo ARKit genera su propia malla, que se exporta a STL.
final class LiDARFusionScanner: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
    enum TrackingQuality: Equatable {
        case good, limited(String), lost
    }

    struct Settings {
        /// Tamaño de vóxel (resolución de la nube) en metros.
        var voxelSize: Float = 0.003
        /// Ventana de trabajo del LiDAR, como la "distancia de trabajo" de un escáner.
        var minDepth: Float = 0.15
        var maxDepth: Float = 1.5
        /// Solo usar mediciones de confianza alta (descarta bordes y superficies oscuras).
        var highConfidenceOnly = true
    }

    @Published private(set) var pointCount = 0
    @Published private(set) var tracking: TrackingQuality = .limited("Iniciando…")
    @Published private(set) var isScanning = false
    @Published var regionCenter: SIMD3<Float>?
    @Published var regionRadius: Float = 0.4

    let session = ARSession()
    var settings = Settings()

    private let processingQueue = DispatchQueue(label: "com.scanforge.lidar.fusion", qos: .userInitiated)
    private var cloud = VoxelCloud(voxelSize: 0.003)
    private var isProcessingFrame = false
    private var lastProcessedTimestamp: TimeInterval = 0
    /// ~6 fotogramas/s de fusión: suficiente para cubrir y deja CPU para ARKit.
    private let minFrameInterval: TimeInterval = 1.0 / 6.0

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = processingQueue
    }

    func run() {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .none
        // Formato de vídeo de mayor resolución para colorear mejor la nube.
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = best
        }
        let voxelSize = settings.voxelSize
        processingQueue.async { self.cloud = VoxelCloud(voxelSize: voxelSize) }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
        setScanning(false)
    }

    func setScanning(_ scanning: Bool) {
        DispatchQueue.main.async { self.isScanning = scanning }
        processingQueue.async { self.scanningFlag = scanning }
    }

    func reset() {
        processingQueue.async {
            self.cloud.removeAll()
            DispatchQueue.main.async { self.pointCount = 0 }
        }
    }

    private var scanningFlag = false
    private var regionSnapshot: (center: SIMD3<Float>?, radius: Float) = (nil, 0.4)

    func updateRegion(center: SIMD3<Float>?, radius: Float) {
        regionCenter = center
        regionRadius = radius
        processingQueue.async { self.regionSnapshot = (center, radius) }
    }

    /// Snapshot para la vista 3D en vivo (submuestreado).
    func previewSnapshot(limit: Int = 120_000, completion: @escaping (VoxelCloud.Snapshot) -> Void) {
        processingQueue.async {
            let stride = max(1, self.cloud.count / limit)
            let snap = self.cloud.snapshot(minObservations: 1, stride: stride)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateTracking(frame.camera.trackingState)
        guard scanningFlag, !isProcessingFrame else { return }
        guard frame.timestamp - lastProcessedTimestamp >= minFrameInterval else { return }
        guard case .normal = frame.camera.trackingState else { return }
        lastProcessedTimestamp = frame.timestamp
        isProcessingFrame = true
        integrate(frame)
        isProcessingFrame = false
        let count = cloud.count
        DispatchQueue.main.async { self.pointCount = count }
    }

    private func updateTracking(_ state: ARCamera.TrackingState) {
        let quality: TrackingQuality
        switch state {
        case .normal: quality = .good
        case .notAvailable: quality = .lost
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: quality = .limited("Muévete más despacio")
            case .insufficientFeatures: quality = .limited("Poca textura: añade luz o objetos alrededor")
            case .initializing: quality = .limited("Iniciando…")
            case .relocalizing: quality = .limited("Recuperando posición…")
            @unknown default: quality = .limited("Seguimiento limitado")
            }
        }
        DispatchQueue.main.async {
            if self.tracking != quality { self.tracking = quality }
        }
    }

    /// Proyecta el mapa de profundidad al mundo y lo fusiona en la rejilla.
    private func integrate(_ frame: ARFrame) {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthMap = depth.depthMap
        let confidenceMap = depth.confidenceMap
        let image = frame.capturedImage

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        if let confidenceMap {
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        }

        // Imagen YCbCr 4:2:0 bi-planar (formato nativo de ARKit).
        guard CVPixelBufferGetPlaneCount(image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)

        // Los intrínsecos vienen para la resolución de la imagen; se escalan al mapa de profundidad.
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(depthWidth) / Float(frame.camera.imageResolution.width)
        let scaleY = Float(depthHeight) / Float(frame.camera.imageResolution.height)
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY
        let cameraToWorld = frame.camera.transform
        let rotation = simd_float3x3(
            SIMD3<Float>(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            SIMD3<Float>(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            SIMD3<Float>(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        )

        let minDepth = settings.minDepth
        let maxDepth = settings.maxDepth
        let requiredConfidence: UInt8 = settings.highConfidenceOnly ? 2 : 1
        let region = regionSnapshot
        let radiusSquared = region.radius * region.radius
        let imageScaleX = Float(imageWidth) / Float(depthWidth)
        let imageScaleY = Float(imageHeight) / Float(depthHeight)

        @inline(__always)
        func depthAt(_ u: Int, _ v: Int) -> Float {
            depthBase.advanced(by: v * depthRowBytes + u * 4).assumingMemoryBound(to: Float32.self).pointee
        }

        /// Punto en coordenadas de cámara de ARKit (X derecha, Y arriba, Z hacia atrás).
        @inline(__always)
        func cameraPoint(_ u: Int, _ v: Int, _ d: Float) -> SIMD3<Float> {
            let x = (Float(u) - cx) * d / fx
            let y = (Float(v) - cy) * d / fy
            return SIMD3<Float>(x, -y, -d)
        }

        let step = 2
        var v = step
        while v < depthHeight - step {
            var u = step
            while u < depthWidth - step {
                defer { u += step }
                let d = depthAt(u, v)
                guard d >= minDepth, d <= maxDepth, d.isFinite else { continue }
                if let confidenceBase {
                    let c = confidenceBase.advanced(by: v * confidenceRowBytes + u).assumingMemoryBound(to: UInt8.self).pointee
                    guard c >= requiredConfidence else { continue }
                }

                let pc = cameraPoint(u, v, d)
                let world4 = cameraToWorld * SIMD4<Float>(pc, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                if let center = region.center, simd_distance_squared(world, center) > radiusSquared { continue }

                // Normal local a partir de los vecinos del mapa de profundidad.
                let dRight = depthAt(u + step, v)
                let dDown = depthAt(u, v + step)
                var normal = SIMD3<Float>(0, 0, 0)
                if dRight > 0, dDown > 0, abs(dRight - d) < 0.05, abs(dDown - d) < 0.05 {
                    let a = cameraPoint(u + step, v, dRight) - pc
                    let b = cameraPoint(u, v + step, dDown) - pc
                    var n = simd_cross(b, a)
                    if simd_dot(n, pc) > 0 { n = -n }
                    let length = simd_length(n)
                    if length > 1e-9 { normal = rotation * (n / length) }
                }

                // Color del píxel equivalente en la imagen de cámara.
                let iu = min(Int(Float(u) * imageScaleX), imageWidth - 1)
                let iv = min(Int(Float(v) * imageScaleY), imageHeight - 1)
                let yValue = Float(yBase.advanced(by: iv * yRowBytes + iu).assumingMemoryBound(to: UInt8.self).pointee)
                let cbcr = cbcrBase.advanced(by: (iv / 2) * cbcrRowBytes + (iu / 2) * 2).assumingMemoryBound(to: UInt8.self)
                let cb = Float(cbcr[0]) - 128
                let cr = Float(cbcr[1]) - 128
                let rgb = SIMD3<Float>(
                    yValue + 1.402 * cr,
                    yValue - 0.344136 * cb - 0.714136 * cr,
                    yValue + 1.772 * cb
                ) / 255

                // Las mediciones cercanas son más precisas en LiDAR: pesan más.
                cloud.add(point: world, color: rgb, normal: normal, weight: 1 / max(d, 0.2))
            }
            v += step
        }
    }

    // MARK: - Exportación

    struct ExportResult {
        let files: [URL]
        let points: Int
        let triangles: Int
    }

    /// Exporta la nube fusionada (PLY) y la malla LiDAR de ARKit (STL + OBJ), en mm.
    func export(to folder: URL, baseName: String, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        let anchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let region = (regionCenter, regionRadius)
        processingQueue.async {
            do {
                var files: [URL] = []
                let snapshot = self.cloud.snapshot(minObservations: 2)
                let plyURL = folder.appendingPathComponent("\(baseName)-nube.ply")
                try MeshExporter.writePointCloud(snapshot, to: plyURL)
                files.append(plyURL)

                let mesh = MeshExporter.mesh(from: anchors).cropped(center: region.0, radius: region.1)
                if !mesh.isEmpty {
                    let stlURL = folder.appendingPathComponent("\(baseName)-lidar.stl")
                    let objURL = folder.appendingPathComponent("\(baseName)-lidar.obj")
                    try MeshExporter.writeSTL(mesh, to: stlURL)
                    try MeshExporter.writeOBJ(mesh, to: objURL)
                    files.append(contentsOf: [stlURL, objURL])
                }
                let result = ExportResult(files: files, points: snapshot.positions.count, triangles: mesh.triangleCount)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
