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
    @State private var model: SCNNode?
    @State private var ar = true
    @State private var showPicker = false
    @State private var loading = false
    @State private var error: String?
    @State private var resetTick = 0
    @State private var status: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ar { ARSceneView(model: model, resetTick: resetTick).ignoresSafeArea() }
            else { ViewerSceneView(model: model).ignoresSafeArea() }

            VStack {
                HStack {
                    Picker("", selection: $ar) {
                        Text("AR").tag(true)
                        Text("3D").tag(false)
                    }.pickerStyle(.segmented).frame(width: 140)
                    Spacer()
                    if model != nil && ar {
                        Button { resetTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.bordered)
                    }
                    Button { showPicker = true } label: { Label("Відкрити", systemImage: "folder") }
                        .buttonStyle(.borderedProminent)
                }.padding()
                Spacer()
                VStack(spacing: 8) {
                    if loading { ProgressView("Завантаження моделі…") }
                    if let status { Text(status).foregroundStyle(.green) }
                    if model == nil && !loading {
                        Text("Відкрий 3D-модель: GLB, GLTF, USDZ, OBJ, STL, PLY, DAE, SCN, ABC")
                    } else if ar {
                        Text("Тягни — перемістити · два пальці: обертати й масштабувати")
                    }
                }
                .font(.footnote).multilineTextAlignment(.center)
                .padding(12).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .sheet(isPresented: $showPicker) {
            DocPicker { urls in
                showPicker = false
                Task { await open(urls) }
            }.ignoresSafeArea()
        }
        .alert("Не вдалося відкрити", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onOpenURL { u in Task { await open([u]) } }
    }

    func open(_ urls: [URL]) async {
        loading = true
        error = nil
        defer { loading = false }
        status = nil
        do {
            model = try await ModelLoader.load(urls)
            status = "Завантажено: " + urls.map { $0.lastPathComponent }.joined(separator: ", ")
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
