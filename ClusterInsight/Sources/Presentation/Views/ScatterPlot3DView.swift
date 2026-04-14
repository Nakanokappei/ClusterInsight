import SwiftUI
import SceneKit

// 3D scatter plot visualization of UMAP-reduced embeddings using SceneKit.
// Each point is colored by its cluster assignment and supports interactive
// camera rotation and zoom via built-in SceneKit controls.
struct ScatterPlot3DView: NSViewRepresentable {
    @Bindable var appState: AppState

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .black
        scnView.antialiasingMode = .multisampling4X

        let scene = buildScene()
        scnView.scene = scene

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Rebuild the scene when data or selection changes.
        nsView.scene = buildScene()
    }

    // Build a SceneKit scene with scatter plot points, axes, and camera.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()

        guard !appState.coordinates.isEmpty else { return scene }

        // Normalize coordinates to a displayable range.
        let normalizedCoords = normalizeCoordinates(appState.coordinates)

        // Build a lookup from record ID to cluster label for coloring.
        let labelByRecordId = Dictionary(
            uniqueKeysWithValues: appState.clusterAssignments.map { ($0.recordId, $0.clusterLabel) }
        )

        // Create a sphere node for each data point.
        // Dynamic sphere radius based on data count (smaller for more points).
        let pointRadius: CGFloat = CGFloat(max(0.012, 0.04 / pow(Double(normalizedCoords.count), 0.15)))
        for (index, coord) in normalizedCoords.enumerated() {
            let recordId = appState.coordinates[index].recordId
            let clusterLabel = labelByRecordId[recordId] ?? -1

            let sphere = SCNSphere(radius: pointRadius)
            sphere.segmentCount = 8 // Reduce polygon count for performance.
            let nsColor = ClusterColors.nsColor(for: clusterLabel)

            // Dim unselected clusters when a cluster is selected.
            let isHighlighted = appState.selectedClusterLabel == nil ||
                appState.selectedClusterLabel == clusterLabel
            let alpha: CGFloat = isHighlighted ? 1.0 : 0.15

            sphere.firstMaterial?.diffuse.contents = nsColor.withAlphaComponent(alpha)
            sphere.firstMaterial?.lightingModel = .constant

            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(coord.x, coord.y, coord.z)
            scene.rootNode.addChildNode(node)
        }

        // Add coordinate axes for spatial reference.
        addAxes(to: scene.rootNode)

        // Configure the camera for an overview of the data.
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        cameraNode.position = SCNVector3(3, 3, 5)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    // Normalize 3D coordinates to fit within a [-2, 2] cube centered at the origin.
    private func normalizeCoordinates(_ coords: [DimensionReductionCoord]) -> [(x: Float, y: Float, z: Float)] {
        let xs: [Float] = coords.map { Float($0.x) }
        let ys: [Float] = coords.map { Float($0.y) }
        let zs: [Float] = coords.map { Float($0.z) }

        let xRange: Float = (xs.max() ?? 0) - (xs.min() ?? 0)
        let yRange: Float = (ys.max() ?? 0) - (ys.min() ?? 0)
        let zRange: Float = (zs.max() ?? 0) - (zs.min() ?? 0)
        let maxRange: Float = max(xRange, max(yRange, zRange))
        let scale: Float = maxRange > 0 ? 4.0 / maxRange : 1.0

        let centerX: Float = ((xs.max() ?? 0) + (xs.min() ?? 0)) / 2
        let centerY: Float = ((ys.max() ?? 0) + (ys.min() ?? 0)) / 2
        let centerZ: Float = ((zs.max() ?? 0) + (zs.min() ?? 0)) / 2

        return coords.map { coord in
            let nx: Float = (Float(coord.x) - centerX) * scale
            let ny: Float = (Float(coord.y) - centerY) * scale
            let nz: Float = (Float(coord.z) - centerZ) * scale
            return (x: nx, y: ny, z: nz)
        }
    }

    // Add thin cylinder axes lines through the origin for spatial reference.
    private func addAxes(to rootNode: SCNNode) {
        let axisLength: CGFloat = 3.0
        let axisRadius: CGFloat = 0.005

        // X axis (red), Y axis (green), Z axis (blue).
        let axisConfigs: [(NSColor, SCNVector3, SCNVector4)] = [
            (.red,   SCNVector3(Float(axisLength / 2), 0, 0), SCNVector4(0, 0, 1, Float.pi / 2)),
            (.green, SCNVector3(0, Float(axisLength / 2), 0), SCNVector4(0, 0, 0, 0)),
            (.blue,  SCNVector3(0, 0, Float(axisLength / 2)), SCNVector4(1, 0, 0, Float.pi / 2))
        ]

        for (color, position, rotation) in axisConfigs {
            let cylinder = SCNCylinder(radius: axisRadius, height: axisLength)
            cylinder.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.3)
            cylinder.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: cylinder)
            node.position = position
            node.rotation = rotation
            rootNode.addChildNode(node)
        }
    }
}

// NSColor versions of the cluster colors for SceneKit materials.
extension ClusterColors {
    static func nsColor(for label: Int) -> NSColor {
        if label < 0 { return NSColor.gray.withAlphaComponent(0.3) }

        let nsColors: [NSColor] = [
            .systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple,
            .systemPink, .systemTeal, .systemIndigo, .systemMint, .systemBrown,
            .cyan, .yellow, .gray, .white, .lightGray,
            NSColor.systemBlue.withAlphaComponent(0.6),
            NSColor.systemRed.withAlphaComponent(0.6),
            NSColor.systemGreen.withAlphaComponent(0.6),
            NSColor.systemOrange.withAlphaComponent(0.6),
            NSColor.systemPurple.withAlphaComponent(0.6)
        ]
        return nsColors[label % nsColors.count]
    }
}
