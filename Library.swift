import SwiftUI
import SceneKit

// MARK: Бібліотека (вбудовані фігури + збережені моделі)
struct LibItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var file: String   // шлях відносно папки Library
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var items: [LibItem] = []
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([LibItem].self, from: d) {
            items = list.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) }
        }
    }
    private func save() { try? JSONEncoder().encode(items).write(to: indexURL) }
    func fileURL(_ it: LibItem) -> URL { root.appendingPathComponent(it.file) }

    func add(name: String, stagedDir: URL, mainFile: String) throws {
        let id = UUID()
        try FileManager.default.copyItem(at: stagedDir, to: root.appendingPathComponent(id.uuidString))
        items.insert(LibItem(id: id, name: name, file: id.uuidString + "/" + mainFile), at: 0)
        save()
    }
    func delete(_ it: LibItem) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(it.id.uuidString))
        items.removeAll { $0.id == it.id }
        save()
    }
}

struct Builtin: Identifiable {
    let id: String
    let name: String
    let icon: String
    let make: () -> SCNGeometry
}

enum Builtins {
    static let all: [Builtin] = [
        Builtin(id: "box", name: "Куб", icon: "cube") { SCNBox(width: 0.3, height: 0.3, length: 0.3, chamferRadius: 0.01) },
        Builtin(id: "sphere", name: "Сфера", icon: "circle") { SCNSphere(radius: 0.15) },
        Builtin(id: "torus", name: "Тор", icon: "circle.dashed") { SCNTorus(ringRadius: 0.15, pipeRadius: 0.05) },
        Builtin(id: "pyramid", name: "Піраміда", icon: "triangle") { SCNPyramid(width: 0.3, height: 0.3, length: 0.3) },
        Builtin(id: "cylinder", name: "Циліндр", icon: "cylinder") { SCNCylinder(radius: 0.12, height: 0.3) },
        Builtin(id: "cone", name: "Конус", icon: "cone") { SCNCone(topRadius: 0, bottomRadius: 0.15, height: 0.3) },
        Builtin(id: "capsule", name: "Капсула", icon: "capsule") { SCNCapsule(capRadius: 0.08, height: 0.35) }
    ]
    static func node(_ b: Builtin) -> SCNNode {
        let g = b.make()
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.85, alpha: 1)
        m.metalness.contents = 0.1
        m.roughness.contents = 0.5
        g.materials = [m]
        return ModelLoader.wrap(SCNNode(geometry: g))
    }
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    let onBuiltin: (Builtin) -> Void
    let onItem: (LibItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Вбудовані фігури") {
                    ForEach(Builtins.all) { b in
                        Button { onBuiltin(b); dismiss() } label: { Label(b.name, systemImage: b.icon) }
                    }
                }
                Section("Мої моделі") {
                    if store.items.isEmpty {
                        Text("Порожньо. Відкриті моделі зберігаються тут автоматично.").foregroundStyle(.secondary)
                    }
                    ForEach(store.items) { it in
                        Button { onItem(it); dismiss() } label: { Label(it.name, systemImage: "cube.fill") }
                    }
                    .onDelete { offsets in
                        let victims = offsets.map { store.items[$0] }
                        for v in victims { store.delete(v) }
                    }
                }
            }
            .navigationTitle("Бібліотека")
            .toolbar { Button("Готово") { dismiss() } }
        }
    }
}

// MARK: Розфарбовування (по частинах моделі)
enum Painter {
    private static var saved: [ObjectIdentifier: (SCNGeometry, [SCNMaterial])] = [:]

    static func forget() { saved = [:] }
    static func reset() {
        for (_, v) in saved { v.0.materials = v.1 }
        saved = [:]
    }
    private static func remember(_ g: SCNGeometry) {
        if saved[ObjectIdentifier(g)] == nil { saved[ObjectIdentifier(g)] = (g, g.materials) }
    }
    private static func tinted(_ m: SCNMaterial, _ c: UIColor) -> SCNMaterial {
        let n = (m.copy() as? SCNMaterial) ?? m
        n.diffuse.contents = c
        n.diffuse.contentsTransform = SCNMatrix4Identity
        return n
    }

    static func paint(_ hit: SCNHitTestResult, _ c: UIColor) {
        guard let g = hit.node.geometry, !g.materials.isEmpty else { return }
        remember(g)
        let i = min(max(hit.geometryIndex, 0), g.materials.count - 1)
        g.replaceMaterial(at: i, with: tinted(g.materials[i], c))
    }

    static func paintAll(_ root: SCNNode, _ c: UIColor) {
        root.enumerateHierarchy { n, _ in
            guard let g = n.geometry else { return }
            remember(g)
            g.materials = g.materials.map { tinted($0, c) }
        }
    }

    // Якщо текстури виглядають «розсипаними» — перевертає їх по вертикалі
    static func flipTextures(_ root: SCNNode) {
        var seen = Set<ObjectIdentifier>()
        root.enumerateHierarchy { n, _ in
            for m in n.geometry?.materials ?? [] {
                if seen.contains(ObjectIdentifier(m)) { continue }
                seen.insert(ObjectIdentifier(m))
                for p in [m.diffuse, m.normal, m.emission] where p.contents is UIImage {
                    p.contentsTransform = SCNMatrix4Mult(p.contentsTransform, GLTFLoader.flip)
                }
            }
        }
    }
}
