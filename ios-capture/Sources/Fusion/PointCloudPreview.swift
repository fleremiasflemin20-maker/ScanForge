import SceneKit
import SwiftUI
import simd

/// Vista 3D en vivo de la nube fusionada (como la ventana de previsualización del
/// software de Creality Scan / Revo Scan). Se puede girar y hacer zoom con los dedos.
struct PointCloudPreview: UIViewRepresentable {
    let snapshot: VoxelCloud.Snapshot?
    var pointSize: CGFloat = 3

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.07, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        let scene = SCNScene()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.005
        cameraNode.camera?.zFar = 50
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene, let snapshot, !snapshot.positions.isEmpty else { return }
        if context.coordinator.lastCount == snapshot.positions.count { return }
        let firstFrame = context.coordinator.lastCount == 0
        context.coordinator.lastCount = snapshot.positions.count

        scene.rootNode.childNode(withName: "cloud", recursively: false)?.removeFromParentNode()
        let node = SCNNode(geometry: Self.geometry(from: snapshot, pointSize: pointSize))
        node.name = "cloud"
        scene.rootNode.addChildNode(node)

        if firstFrame || !context.coordinator.userMovedCamera(view) {
            frame(view: view, snapshot: snapshot, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastCount = 0
        var framedTransform: SCNMatrix4?

        func userMovedCamera(_ view: SCNView) -> Bool {
            guard let framed = framedTransform, let pov = view.pointOfView else { return false }
            return !SCNMatrix4EqualToMatrix4(framed, pov.transform)
        }
    }

    private func frame(view: SCNView, snapshot: VoxelCloud.Snapshot, coordinator: Coordinator) {
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in snapshot.positions {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let center = (minP + maxP) / 2
        let extent = max(simd_length(maxP - minP), 0.05)
        guard let pov = view.pointOfView else { return }
        pov.position = SCNVector3(center.x, center.y + extent * 0.4, center.z + extent * 1.2)
        pov.look(at: SCNVector3(center.x, center.y, center.z))
        view.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
        coordinator.framedTransform = pov.transform
    }

    static func geometry(from snapshot: VoxelCloud.Snapshot, pointSize: CGFloat) -> SCNGeometry {
        let count = snapshot.positions.count
        let vertexData = snapshot.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colors = snapshot.colors.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
        )
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let indices = (0..<UInt32(count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point, primitiveCount: count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = pointSize * 2

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }
}
