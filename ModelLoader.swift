import SceneKit
import SceneKit.ModelIO
#if canImport(GLTFKit2)
import GLTFKit2
#endif

enum ModelError: LocalizedError {
    case noModel(String), failed
    var errorDescription: String? {
        switch self {
        case .noModel(let ext):
            return ext.isEmpty ? "Не знайшов файл моделі."
                : "Формат .\(ext) напряму не підтримується. Конвертуй модель у GLB або USDZ."
        case .failed: return "Не вдалося відкрити модель."
        }
    }
}

enum ModelLoader {
    // GLB/GLTF — через GLTFKit2; решта — SceneKit/ModelIO
    static let supported = ["glb", "gltf", "usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "dae", "scn", "abc"]
    private static func rank(_ u: URL) -> Int { supported.firstIndex(of: u.pathExtension.lowercased()) ?? supported.count }

    // Можна вибрати кілька файлів одразу (напр. .obj + .mtl + текстури)
    static func load(_ urls: [URL]) async throws -> SCNNode {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var copied: [URL] = []
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            try FileManager.default.copyItem(at: u, to: dest)
            copied.append(dest)
        }
        guard let file = copied.min(by: { rank($0) < rank($1) }), rank(file) < supported.count else {
            throw ModelError.noModel(copied.first?.pathExtension.lowercased() ?? "")
        }
        let scene: SCNScene
        if ["glb", "gltf"].contains(file.pathExtension.lowercased()) {
            scene = try await loadGLTF(file)
        } else {
            scene = try SCNScene(url: file, options: nil)
        }
        return normalize(scene)
    }

    private static func loadGLTF(_ url: URL) async throws -> SCNScene {
        #if canImport(GLTFKit2)
        return try await withCheckedThrowingContinuation { cont in
            GLTFAsset.load(with: url, options: [:]) { _, status, asset, error, _ in
                if status == .complete {
                    if let asset {
                        cont.resume(returning: GLTFSCNSceneSource(asset: asset).defaultScene ?? SCNScene())
                    } else { cont.resume(throwing: ModelError.failed) }
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
        #else
        throw ModelError.noModel(url.pathExtension.lowercased())
        #endif
    }

    // Масштабуємо до ~0.5 м, ставимо центр основи в (0,0,0)
    private static func normalize(_ scene: SCNScene) -> SCNNode {
        let content = SCNNode()
        for c in scene.rootNode.childNodes { content.addChildNode(c) }
        let (mn, mx) = content.boundingBox
        let maxDim = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z))
        if maxDim > 0 {
            let s = 0.5 / maxDim
            content.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, mn.y, (mn.z + mx.z) / 2)
            content.scale = SCNVector3(s, s, s)
        }
        let holder = SCNNode()
        holder.addChildNode(content)
        return holder
    }
}
