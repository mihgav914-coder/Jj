import SwiftUI
import SceneKit
import ARKit

// MARK: AR
final class ARCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var view: ARSCNView?
    var source: SCNNode?
    var node: SCNNode?
    var lastTick = 0

    func setModel(_ n: SCNNode?) {
        guard n !== source else { return }
        node?.removeFromParentNode()
        source = n
        node = n?.clone()
        guard let node, let v = view else { return }
        node.simdPosition = SIMD3<Float>(0, -0.3, -1)
        v.scene.rootNode.addChildNode(node)
        placeAtCenter()
    }

    func reset() {
        node?.simdScale = SIMD3<Float>(repeating: 1)
        node?.eulerAngles = SCNVector3Zero
        placeAtCenter()
    }

    @discardableResult
    func place(at p: CGPoint) -> Bool {
        guard let v = view, let node,
              let q = v.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .any),
              let r = v.session.raycast(q).first else { return false }
        let c = r.worldTransform.columns.3
        node.simdWorldPosition = SIMD3<Float>(c.x, c.y, c.z)
        return true
    }

    func placeAtCenter() {
        guard let v = view, let node else { return }
        if v.bounds.width > 0, place(at: CGPoint(x: v.bounds.midX, y: v.bounds.midY)) { return }
        if let f = v.session.currentFrame {
            var t = matrix_identity_float4x4
            t.columns.3.z = -1
            let w = simd_mul(f.camera.transform, t).columns.3
            node.simdWorldPosition = SIMD3<Float>(w.x, w.y - 0.3, w.z)
        }
    }

    @objc func tap(_ g: UITapGestureRecognizer) { place(at: g.location(in: view)) }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        if g.state == .began || g.state == .changed { place(at: g.location(in: view)) }
    }
    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        guard let node, g.state == .changed else { return }
        let s = min(max(node.simdScale.x * Float(g.scale), 0.05), 50)
        node.simdScale = SIMD3<Float>(repeating: s)
        g.scale = 1
    }
    @objc func rotate(_ g: UIRotationGestureRecognizer) {
        guard let node, g.state == .changed else { return }
        node.eulerAngles.y -= Float(g.rotation)
        g.rotation = 0
    }
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
}

struct ARSceneView: UIViewRepresentable {
    let model: SCNNode?
    let resetTick: Int

    func makeCoordinator() -> ARCoordinator { ARCoordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.autoenablesDefaultLighting = true
        v.automaticallyUpdatesLighting = true
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        cfg.environmentTexturing = .automatic
        v.session.run(cfg)

        let c = context.coordinator
        c.view = v
        let tap = UITapGestureRecognizer(target: c, action: #selector(ARCoordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(ARCoordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(ARCoordinator.pinch(_:)))
        let rot = UIRotationGestureRecognizer(target: c, action: #selector(ARCoordinator.rotate(_:)))
        for g in [tap, pan, pinch, rot] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ v: ARSCNView, context: Context) {
        let c = context.coordinator
        c.setModel(model)
        if c.lastTick != resetTick { c.lastTick = resetTick; c.reset() }
    }

    static func dismantleUIView(_ v: ARSCNView, coordinator: ARCoordinator) { v.session.pause() }
}

// MARK: 3D-перегляд (орбіта, зум)
struct ViewerSceneView: UIViewRepresentable {
    let model: SCNNode?
    final class Box { var source: SCNNode? }
    func makeCoordinator() -> Box { Box() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        let scene = SCNScene()
        v.scene = scene
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = UIColor(white: 0.08, alpha: 1)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.01
        cam.camera?.zFar = 100
        cam.position = SCNVector3(0, 0.3, 1.1)
        scene.rootNode.addChildNode(cam)
        v.pointOfView = cam
        v.defaultCameraController.target = SCNVector3(0, 0.25, 0)
        v.defaultCameraController.interactionMode = .orbitTurntable
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        guard model !== context.coordinator.source else { return }
        context.coordinator.source = model
        v.scene?.rootNode.childNode(withName: "model", recursively: false)?.removeFromParentNode()
        if let m = model {
            let c = m.clone()
            c.name = "model"
            v.scene?.rootNode.addChildNode(c)
        }
    }
}
