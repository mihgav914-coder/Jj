import SwiftUI
import SceneKit

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
                    if let error { Text(error).foregroundStyle(.red) }
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
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await open(urls) } }
        }
        .onOpenURL { u in Task { await open([u]) } }
    }

    func open(_ urls: [URL]) async {
        loading = true
        error = nil
        defer { loading = false }
        do { model = try await ModelLoader.load(urls) }
        catch { self.error = error.localizedDescription }
    }
}
