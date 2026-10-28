import AVFoundation
import Foundation
import simd

/// Escáner de luz estructurada con la cámara TrueDepth (proyector de puntos infrarrojos
/// + cámara IR), el mismo principio que el modo NIR de los escáneres de escritorio.
///
/// Flujo por fotograma (≈10–15 fps):
/// 1. Profundidad filtrada → puntos 3D con normales (y color de la cámara frontal).
/// 2. Modo plataforma: se detecta el plano de la plataforma por RANSAC y se elimina,
///    así solo se sigue al objeto que gira.
/// 3. ICP punto-a-plano contra el modelo para obtener la pose (sin marcadores).
/// 4. Si el encaje es bueno, el fotograma se fusiona en la rejilla fina.
final class TrueDepthScanner: NSObject, ObservableObject, @unchecked Sendable {
    enum TrackingState: Equatable {
        case idle, tracking, lost
    }

    struct Settings {
        var minDepth: Float = 0.12
        var maxDepth: Float = 0.45
        /// Resolución de la nube final (metros).
        var voxelSize: Float = 0.001
        /// Plataforma giratoria: iPhone quieto, el objeto gira. Elimina el plano de apoyo.
        var turntableMode = true
    }

    @Published private(set) var pointCount = 0
    @Published private(set) var tracking: TrackingState = .idle
    @Published private(set) var planeDetected = false
    @Published private(set) var isScanning = false
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var errorMessage: String?

    let captureSession = AVCaptureSession()
    var settings = Settings()

    private let depthOutput = AVCaptureDepthDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let sessionQueue = DispatchQueue(label: "com.scanforge.truedepth.session")
    private let dataQueue = DispatchQueue(label: "com.scanforge.truedepth.data", qos: .userInitiated)

    // Estado de fusión (solo se toca desde dataQueue).
    private var fineCloud = VoxelCloud(voxelSize: 0.001)
    private var trackingCloud = VoxelCloud(voxelSize: 0.004)
    private var pose = matrix_identity_float4x4
    private var velocity = matrix_identity_float4x4
    private var plane: DetectedPlane?
    private var hasModel = false
    private var scanningFlag = false
    private var consecutiveFailures = 0
    private var processedFrames = 0
    private var fpsWindowStart = Date()

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    // MARK: - Sesión de cámara

    func start() {
        sessionQueue.async {
            if self.captureSession.inputs.isEmpty {
                self.configure()
            }
            self.captureSession.startRunning()
        }
    }

    func stop() {
        setScanning(false)
        sessionQueue.async { self.captureSession.stopRunning() }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            report("Este iPhone no tiene cámara TrueDepth.")
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            report("No se pudo usar la cámara TrueDepth.")
            return
        }
        captureSession.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = true
        if captureSession.canAddOutput(depthOutput) { captureSession.addOutput(depthOutput) }
        depthOutput.connection(with: .depthData)?.isEnabled = true

        // Formato de profundidad Float32 de mayor resolución disponible.
        let depthFormats = device.activeFormat.supportedDepthDataFormats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        if let best = depthFormats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) {
            do {
                try device.lockForConfiguration()
                device.activeDepthDataFormat = best
                device.unlockForConfiguration()
            } catch {
                report("No se pudo configurar la profundidad: \(error.localizedDescription)")
            }
        }
        captureSession.commitConfiguration()

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: dataQueue)
        self.synchronizer = synchronizer
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    // MARK: - Control del escaneo

    func setScanning(_ scanning: Bool) {
        let voxelSize = settings.voxelSize
        dataQueue.async {
            if scanning && !self.hasModel && self.fineCloud.voxelSize != voxelSize {
                self.fineCloud = VoxelCloud(voxelSize: voxelSize)
            }
            self.scanningFlag = scanning
        }
        DispatchQueue.main.async {
            self.isScanning = scanning
            self.tracking = scanning ? .tracking : .idle
        }
    }

    func reset() {
        dataQueue.async {
            self.fineCloud = VoxelCloud(voxelSize: self.settings.voxelSize)
            self.trackingCloud.removeAll()
            self.pose = matrix_identity_float4x4
            self.velocity = matrix_identity_float4x4
            self.plane = nil
            self.hasModel = false
            self.consecutiveFailures = 0
            DispatchQueue.main.async {
                self.pointCount = 0
                self.planeDetected = false
            }
        }
    }

    func previewSnapshot(limit: Int = 120_000, completion: @escaping (VoxelCloud.Snapshot) -> Void) {
        dataQueue.async {
            let stride = max(1, self.fineCloud.count / limit)
            let snap = self.fineCloud.snapshot(minObservations: 2, stride: stride)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    func export(to folder: URL, baseName: String, completion: @escaping (Result<(URL, Int), Error>) -> Void) {
        dataQueue.async {
            do {
                let snapshot = self.fineCloud.snapshot(minObservations: 3)
                let url = folder.appendingPathComponent("\(baseName)-truedepth.ply")
                try MeshExporter.writePointCloud(snapshot, to: url)
                DispatchQueue.main.async { completion(.success((url, snapshot.positions.count))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Procesado de fotogramas

    private struct FramePoints {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
    }

    fileprivate func process(depthData rawDepth: AVDepthData, video: CMSampleBuffer?) {
        guard scanningFlag else { return }
        let depthData = rawDepth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? rawDepth
            : rawDepth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        var frame = extractPoints(depthData: depthData, video: video.flatMap(CMSampleBufferGetImageBuffer))
        guard frame.positions.count > 500 else { return }

        if settings.turntableMode {
            if plane == nil {
                plane = DetectedPlane.ransac(points: frame.positions)
                if plane != nil { DispatchQueue.main.async { self.planeDetected = true } }
            }
            if let plane {
                var kept = FramePoints()
                for i in frame.positions.indices where plane.signedDistance(frame.positions[i]) > 0.005 {
                    kept.positions.append(frame.positions[i])
                    kept.normals.append(frame.normals[i])
                    kept.colors.append(frame.colors[i])
                }
                frame = kept
                guard frame.positions.count > 300 else { return }
            }
        }

        if hasModel {
            // Modelo de velocidad constante como estimación inicial (la plataforma gira
            // a ritmo casi uniforme), luego ICP la refina.
            let predicted = velocity * pose
            let sampleStride = max(1, frame.positions.count / 2500)
            let samples = Swift.stride(from: 0, to: frame.positions.count, by: sampleStride).map { frame.positions[$0] }
            let result = ICPTracker.align(points: samples, to: trackingCloud, initialPose: predicted)

            guard result.inlierRatio > 0.35, result.rmse < 0.004 else {
                consecutiveFailures += 1
                velocity = matrix_identity_float4x4
                if consecutiveFailures >= 3 {
                    DispatchQueue.main.async { if self.tracking != .lost { self.tracking = .lost } }
                }
                return
            }
            velocity = result.pose * pose.inverse
            pose = result.pose
            consecutiveFailures = 0
            DispatchQueue.main.async { if self.tracking != .tracking { self.tracking = .tracking } }
        }

        integrate(frame, pose: pose)
        hasModel = true
        updateStats()
    }

    private func integrate(_ frame: FramePoints, pose: simd_float4x4) {
        let rotation = simd_float3x3(
            SIMD3<Float>(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        )
        for i in frame.positions.indices {
            let p4 = pose * SIMD4<Float>(frame.positions[i], 1)
            let p = SIMD3<Float>(p4.x, p4.y, p4.z)
            let n = rotation * frame.normals[i]
            // Peso según incidencia: superficies vistas de frente son más fiables.
            let facing = max(0.1, -simd_dot(simd_normalize(frame.positions[i]), frame.normals[i]))
            fineCloud.add(point: p, color: frame.colors[i], normal: n, weight: facing)
            trackingCloud.add(point: p, color: frame.colors[i], normal: n, weight: facing)
        }
    }

    private func updateStats() {
        processedFrames += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        let count = fineCloud.count
        if elapsed >= 1 {
            let fps = Double(processedFrames) / elapsed
            processedFrames = 0
            fpsWindowStart = Date()
            DispatchQueue.main.async {
                self.framesPerSecond = fps
                self.pointCount = count
            }
        }
    }

    /// Mapa de profundidad → puntos en convención de cámara de ARKit
    /// (X derecha, Y arriba, Z hacia atrás), con normales orientadas a la cámara.
    private func extractPoints(depthData: AVDepthData, video: CVPixelBuffer?) -> FramePoints {
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let video { CVPixelBufferLockBaseAddress(video, .readOnly) }
        defer { if let video { CVPixelBufferUnlockBaseAddress(video, .readOnly) } }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return FramePoints() }

        // Intrínsecos: de la calibración si está, si no una aproximación del TrueDepth.
        var fx = Float(width) * 0.87, fy = Float(width) * 0.87
        var cx = Float(width) / 2, cy = Float(height) / 2
        if let calibration = depthData.cameraCalibrationData {
            let k = calibration.intrinsicMatrix
            let reference = calibration.intrinsicMatrixReferenceDimensions
            let sx = Float(width) / Float(reference.width)
            let sy = Float(height) / Float(reference.height)
            fx = k[0][0] * sx
            fy = k[1][1] * sy
            cx = k[2][0] * sx
            cy = k[2][1] * sy
        }

        var colorBase: UnsafeMutableRawPointer?
        var colorRowBytes = 0
        var colorWidth = 0
        var colorHeight = 0
        if let video {
            colorBase = CVPixelBufferGetBaseAddress(video)
            colorRowBytes = CVPixelBufferGetBytesPerRow(video)
            colorWidth = CVPixelBufferGetWidth(video)
            colorHeight = CVPixelBufferGetHeight(video)
        }

        @inline(__always)
        func depthAt(_ u: Int, _ v: Int) -> Float {
            base.advanced(by: v * rowBytes + u * 4).assumingMemoryBound(to: Float32.self).pointee
        }
        @inline(__always)
        func point(_ u: Int, _ v: Int, _ d: Float) -> SIMD3<Float> {
            SIMD3<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d)
        }

        let minDepth = settings.minDepth
        let maxDepth = settings.maxDepth
        let step = width > 400 ? 2 : 1
        var frame = FramePoints()
        frame.positions.reserveCapacity((width / step) * (height / step))
        frame.normals.reserveCapacity((width / step) * (height / step))
        frame.colors.reserveCapacity((width / step) * (height / step))

        var v = step
        while v < height - step {
            var u = step
            while u < width - step {
                defer { u += step }
                let d = depthAt(u, v)
                guard d.isFinite, d >= minDepth, d <= maxDepth else { continue }
                let dr = depthAt(u + step, v)
                let dd = depthAt(u, v + step)
                guard dr.isFinite, dd.isFinite, abs(dr - d) < 0.01, abs(dd - d) < 0.01 else { continue }

                let p = point(u, v, d)
                var n = simd_cross(point(u, v + step, dd) - p, point(u + step, v, dr) - p)
                if simd_dot(n, p) > 0 { n = -n }
                let length = simd_length(n)
                guard length > 1e-12 else { continue }
                n /= length

                var color = SIMD3<Float>(repeating: 0.75)
                if let colorBase {
                    let cu = min(u * colorWidth / width, colorWidth - 1)
                    let cv = min(v * colorHeight / height, colorHeight - 1)
                    let px = colorBase.advanced(by: cv * colorRowBytes + cu * 4).assumingMemoryBound(to: UInt8.self)
                    color = SIMD3<Float>(Float(px[2]), Float(px[1]), Float(px[0])) / 255
                }

                frame.positions.append(p)
                frame.normals.append(n)
                frame.colors.append(color)
            }
            v += step
        }
        return frame
    }
}

extension TrueDepthScanner: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard let depth = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !depth.depthDataWasDropped else { return }
        let video = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData
        let sampleBuffer = (video?.sampleBufferWasDropped == false) ? video?.sampleBuffer : nil
        process(depthData: depth.depthData, video: sampleBuffer)
    }
}
