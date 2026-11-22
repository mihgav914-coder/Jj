import SwiftUI
import SceneKit
import UniformTypeIdentifiers

@main
struct ARViewerApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

struct ContentView: View {
    @StateObject private var store = LibraryStore()
    @State private var model: SCNNode?
    @State private var modelName = ""
    @State private var ar = true
    @State private var showPicker = false
    @State private var showLibrary = false
    @State private var loading = false
    @State private var error: String?
    @State private var status: String?
    @State private var resetTick = 0
    @State private var paintMode = false
    @State private var color = Color.red

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ar {
                ARSceneView(model: model, resetTick: resetTick, paintMode: paintMode, paintColor: UIColor(color)).ignoresSafeArea()
            } else {
                ViewerSceneView(model: model, paintMode: paintMode, paintColor: UIColor(color)).ignoresSafeArea()
            }
            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .sheet(isPresented: $showPicker) {
            DocPicker { urls in
                showPicker = false
                Task { await open(urls) }
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(store: store, onBuiltin: { openBuiltin($0) }, onItem: { openItem($0) })
        }
        .alert("Помилка", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onOpenURL { u in Task { await open([u]) } }
    }

    var topBar: some View {
        HStack {
            Picker("", selection: $ar) {
                Text("AR").tag(true)
                Text("3D").tag(false)
            }.pickerStyle(.segmented).frame(width: 140)
            Spacer()
            if model != nil && ar {
                Button { resetTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.bordered)
            }
            Button { showLibrary = true } label: { Image(systemName: "square.grid.2x2") }.buttonStyle(.bordered)
            Button { showPicker = true } label: { Label("Відкрити", systemImage: "folder") }.buttonStyle(.borderedProminent)
        }.padding()
    }

    var bottomBar: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                if loading { ProgressView("Завантаження моделі…") }
                if let status { Text(status).foregroundStyle(.green) }
                if model == nil && !loading {
                    Text("Відкрий модель (GLB, GLTF, USDZ, OBJ, STL…) або вибери фігуру в бібліотеці")
                } else if paintMode {
                    Text("Торкнись частини моделі, щоб зафарбувати її")
                } else if ar {
                    Text("Тягни — перемістити · два пальці: обертати й масштабувати")
                }
            }
            .font(.footnote).multilineTextAlignment(.center)
            .padding(10).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))

            if model != nil {
                HStack(spacing: 18) {
                    Button { paintMode.toggle() } label: {
                        Image(systemName: "paintbrush.pointed.fill").foregroundStyle(paintMode ? Color.yellow : Color.white)
                    }
                    ColorPicker("", selection: $color).labelsHidden()
                    Button { if let model { Painter.paintAll(model, UIColor(color)) } } label: { Image(systemName: "drop.fill") }
                    Button { Painter.reset() } label: { Image(systemName: "arrow.uturn.backward") }
                    Button { if let model { Painter.flipTextures(model) } } label: { Image(systemName: "arrow.up.arrow.down") }
                    Button { saveColored() } label: { Image(systemName: "square.and.arrow.down") }
                }
                .font(.title3).padding(.horizontal, 18).padding(.vertical, 10)
                .background(.ultraThinMaterial).clipShape(Capsule())
            }
        }.padding()
    }

    @MainActor func open(_ urls: [URL]) async {
        loading = true
        error = nil
        status = nil
        defer { loading = false }
        do {
            let l = try await ModelLoader.load(urls)
            Painter.forget()
            model = l.node
            modelName = l.name
            paintMode = false
            try? store.add(name: l.name, stagedDir: l.dir, mainFile: l.file)
            status = "Завантажено: \(l.name)"
        } catch { self.error = error.localizedDescription }
    }

    @MainActor func openItem(_ it: LibItem) {
        do {
            model = try ModelLoader.read(store.fileURL(it))
            Painter.forget()
            modelName = it.name
            paintMode = false
            status = "Відкрито: \(it.name)"
        } catch { self.error = error.localizedDescription }
    }

    @MainActor func openBuiltin(_ b: Builtin) {
        Painter.forget()
        model = Builtins.node(b)
        modelName = b.name
        paintMode = false
        status = b.name
    }

    // Зберегти розфарбовану модель у бібліотеку (USDZ)
    @MainActor func saveColored() {
        guard let model else { return }
        let scene = SCNScene()
        scene.rootNode.addChildNode(model.clone())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("model.usdz")
            guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
                error = "Не вдалося експортувати модель у USDZ."
                return
            }
            try store.add(name: modelName + " (розфарбована)", stagedDir: dir, mainFile: "model.usdz")
            status = "Збережено в бібліотеку"
        } catch { self.error = error.localizedDescription }
    }
}

// Надійний вибір файлів (UIKit-пікер, копіює файли в пісочницю застосунку)
struct DocPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coord { Coord(onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ f: @escaping ([URL]) -> Void) { onPick = f }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}
