import SceneKit
import UIKit
import simd

// Власний завантажувач GLB / GLTF (без сторонніх бібліотек).
// Підтримує: меші, матеріали (колір, текстури), ієрархію вузлів. Без анімацій і скінінгу.

private extension Data {
    func u16(_ o: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + o])
        let b1 = UInt16(self[startIndex + o + 1])
        return b0 | (b1 << 8)
    }
    func u32(_ o: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + o])
        let b1 = UInt32(self[startIndex + o + 1])
        let b2 = UInt32(self[startIndex + o + 2])
        let b3 = UInt32(self[startIndex + o + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

struct GLTFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class GLTFLoader {
    private struct Acc { let data: Data; let offset: Int; let stride: Int; let count: Int; let n: Int; let type: Int; let norm: Bool }

    private var glbBin: Data?
    private let baseURL: URL
    private var buffers: [Int: Data] = [:]
    private var meshCache: [Int: [SCNGeometry]] = [:]
    private var imageCache: [Int: UIImage] = [:]
    private var json: [String: Any] = [:]
    private var accessors: [[String: Any]] = []
    private var views: [[String: Any]] = []
    private var bufferDefs: [[String: Any]] = []
    private var meshes: [[String: Any]] = []
    private var nodes: [[String: Any]] = []
    private var scenes: [[String: Any]] = []
    private var materials: [[String: Any]] = []
    private var textures: [[String: Any]] = []
    private var images: [[String: Any]] = []

    private init(url: URL) { baseURL = url.deletingLastPathComponent() }

    // glTF: початок координат текстури — зверху зліва, SceneKit — знизу зліва, тому перевертаємо через contentsTransform
    static let flip = SCNMatrix4Mult(SCNMatrix4MakeScale(1, -1, 1), SCNMatrix4MakeTranslation(0, 1, 0))
    static func setTex(_ p: SCNMaterialProperty, _ img: UIImage) {
        p.contents = img
        p.wrapS = .repeat
        p.wrapT = .repeat
        p.mipFilter = .linear
        p.maxAnisotropy = 8
        p.contentsTransform = flip
    }

    static func load(_ url: URL) throws -> SCNScene {
        let l = GLTFLoader(url: url)
        try l.parse(url)
        return try l.buildScene()
    }

    // MARK: Розбір файлу
    private func parse(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "glb" {
            guard data.count > 20, data.u32(0) == 0x46546C67 else { throw GLTFError(message: "Пошкоджений GLB-файл") }
            var off = 12
            var j: [String: Any]?
            while off + 8 <= data.count {
                let len = Int(data.u32(off))
                let type = data.u32(off + 4)
                let start = off + 8
                guard start + len <= data.count else { break }
                let chunk = data.subdata(in: start..<(start + len))
                if type == 0x4E4F534A { j = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] }
                else if type == 0x004E4942 { glbBin = chunk }
                off = start + len
            }
            guard let jj = j else { throw GLTFError(message: "У GLB немає даних моделі") }
            json = jj
        } else {
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GLTFError(message: "Пошкоджений GLTF-файл")
            }
            json = j
        }
        let required = json["extensionsRequired"] as? [String] ?? []
        for e in required where e == "KHR_draco_mesh_compression" || e == "EXT_meshopt_compression" {
            throw GLTFError(message: "Модель стиснена (\(e)) і не підтримується. Експортуй без стиснення або конвертуй у USDZ.")
        }
        accessors = json["accessors"] as? [[String: Any]] ?? []
        views = json["bufferViews"] as? [[String: Any]] ?? []
        bufferDefs = json["buffers"] as? [[String: Any]] ?? []
        meshes = json["meshes"] as? [[String: Any]] ?? []
        nodes = json["nodes"] as? [[String: Any]] ?? []
        scenes = json["scenes"] as? [[String: Any]] ?? []
        materials = json["materials"] as? [[String: Any]] ?? []
        textures = json["textures"] as? [[String: Any]] ?? []
        images = json["images"] as? [[String: Any]] ?? []
    }

    // MARK: Дані
    private func loadURI(_ uri: String) -> Data? {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
        }
        let name = uri.removingPercentEncoding ?? uri
        return try? Data(contentsOf: baseURL.appendingPathComponent(name))
    }

    private func buffer(_ i: Int) throws -> Data {
        if let b = buffers[i] { return b }
        guard i >= 0, i < bufferDefs.count else { throw GLTFError(message: "Некоректний buffer") }
        var d: Data?
        if let uri = bufferDefs[i]["uri"] as? String { d = loadURI(uri) } else { d = glbBin }
        guard let data = d else {
            throw GLTFError(message: "Не знайшов файл даних (.bin). Вибери .gltf разом з .bin і текстурами.")
        }
        buffers[i] = data
        return data
    }

    private func csize(_ t: Int) -> Int { (t == 5126 || t == 5125) ? 4 : ((t == 5123 || t == 5122) ? 2 : 1) }

    private func acc(_ i: Int) throws -> Acc {
        guard i >= 0, i < accessors.count else { throw GLTFError(message: "Некоректний accessor") }
        let a = accessors[i]
        let count = a["count"] as? Int ?? 0
        let type = a["componentType"] as? Int ?? 5126
        let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]
        let n = comps[a["type"] as? String ?? "SCALAR"] ?? 1
        guard let bvi = a["bufferView"] as? Int, bvi < views.count else {
            throw GLTFError(message: "Модель використовує sparse-дані — не підтримується.")
        }
        let v = views[bvi]
        let data = try buffer(v["buffer"] as? Int ?? 0)
        let off = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let size = csize(type)
        let stride = (v["byteStride"] as? Int) ?? (size * n)
        guard count == 0 || off + (count - 1) * stride + size * n <= data.count else {
            throw GLTFError(message: "Пошкоджені дані моделі")
        }
        return Acc(data: data, offset: off, stride: stride, count: count, n: n, type: type, norm: a["normalized"] as? Bool ?? false)
    }

    private func value(_ a: Acc, _ o: Int) -> Float {
        switch a.type {
        case 5126: return Float(bitPattern: a.data.u32(o))
        case 5123: let v = Float(a.data.u16(o)); return a.norm ? v / 65535 : v
        case 5121: let v = Float(a.data[a.data.startIndex + o]); return a.norm ? v / 255 : v
        case 5125: return Float(a.data.u32(o))
        default: return 0
        }
    }

    private func floats(_ i: Int) throws -> [Float] {
        let a = try acc(i)
        let size = csize(a.type)
        var out = [Float]()
        out.reserveCapacity(a.count * a.n)
        for e in 0..<a.count {
            for c in 0..<a.n { out.append(value(a, a.offset + e * a.stride + c * size)) }
        }
        return out
    }

    private func indices(_ i: Int) throws -> [UInt32] {
        let a = try acc(i)
        var out = [UInt32]()
        out.reserveCapacity(a.count)
        for e in 0..<a.count {
            let o = a.offset + e * a.stride
            switch a.type {
            case 5125: out.append(a.data.u32(o))
            case 5123: out.append(UInt32(a.data.u16(o)))
            default: out.append(UInt32(a.data[a.data.startIndex + o]))
            }
        }
        return out
    }

    // MARK: Геометрія
    private func triangles(_ i: [UInt32], mode: Int) -> [UInt32] {
        var o: [UInt32] = []
        if mode == 4 {
            o = Array(i.prefix(i.count / 3 * 3))
        } else if mode == 5 {
            if i.count >= 3 {
                for k in 0..<(i.count - 2) {
                    if k % 2 == 0 { o += [i[k], i[k + 1], i[k + 2]] } else { o += [i[k + 1], i[k], i[k + 2]] }
                }
            }
        } else if i.count >= 3 {
            for k in 1..<(i.count - 1) { o += [i[0], i[k], i[k + 1]] }
        }
        return o
    }

    private func geometries(_ mi: Int) throws -> [SCNGeometry] {
        if let g = meshCache[mi] { return g }
        guard mi >= 0, mi < meshes.count else { return [] }
        var result: [SCNGeometry] = []
        let prims = meshes[mi]["primitives"] as? [[String: Any]] ?? []
        for prim in prims {
            let mode = prim["mode"] as? Int ?? 4
            guard mode >= 4, mode <= 6,
                  let attrs = prim["attributes"] as? [String: Int],
                  let pi = attrs["POSITION"] else { continue }
            let p = try floats(pi)
            let vcount = p.count / 3
            var verts: [SCNVector3] = []
            verts.reserveCapacity(vcount)
            for i in 0..<vcount { verts.append(SCNVector3(p[3 * i], p[3 * i + 1], p[3 * i + 2])) }
            var sources = [SCNGeometrySource(vertices: verts)]
            if let ni = attrs["NORMAL"] {
                let nf = try floats(ni)
                var ns: [SCNVector3] = []
                for i in 0..<(nf.count / 3) { ns.append(SCNVector3(nf[3 * i], nf[3 * i + 1], nf[3 * i + 2])) }
                if ns.count == vcount { sources.append(SCNGeometrySource(normals: ns)) }
            }
            if let ti = attrs["TEXCOORD_0"] {
                let tf = try floats(ti)
                var ts: [CGPoint] = []
                for i in 0..<(tf.count / 2) { ts.append(CGPoint(x: CGFloat(tf[2 * i]), y: CGFloat(tf[2 * i + 1]))) }
                if ts.count == vcount { sources.append(SCNGeometrySource(textureCoordinates: ts)) }
            }
            var idx: [UInt32]
            if let ii = prim["indices"] as? Int { idx = try indices(ii) } else { idx = (0..<UInt32(vcount)).map { $0 } }
            idx = triangles(idx, mode: mode)
            guard !idx.isEmpty else { continue }
            let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
            let g = SCNGeometry(sources: sources, elements: [el])
            g.materials = [material(prim["material"] as? Int)]
            result.append(g)
        }
        meshCache[mi] = result
        return result
    }

    // MARK: Матеріали
    private func image(_ ti: Int) -> UIImage? {
        guard ti >= 0, ti < textures.count, let si = textures[ti]["source"] as? Int else { return nil }
        if let c = imageCache[si] { return c }
        guard si < images.count else { return nil }
        let d = images[si]
        var data: Data?
        if let uri = d["uri"] as? String {
            data = loadURI(uri)
        } else if let bv = d["bufferView"] as? Int, bv < views.count {
            let v = views[bv]
            if let b = try? buffer(v["buffer"] as? Int ?? 0) {
                let off = v["byteOffset"] as? Int ?? 0
                let len = v["byteLength"] as? Int ?? 0
                if off + len <= b.count { data = b.subdata(in: (b.startIndex + off)..<(b.startIndex + off + len)) }
            }
        }
        guard let data, let img = UIImage(data: data) else { return nil }
        imageCache[si] = img
        return img
    }

    private func material(_ mi: Int?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.8, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.8
        guard let mi, mi >= 0, mi < materials.count else { return m }
        let d = materials[mi]
        m.isDoubleSided = d["doubleSided"] as? Bool ?? false
        if let pbr = d["pbrMetallicRoughness"] as? [String: Any] {
            if let f = pbr["baseColorFactor"] as? [Double], f.count == 4 {
                m.diffuse.contents = UIColor(red: CGFloat(f[0]), green: CGFloat(f[1]), blue: CGFloat(f[2]), alpha: CGFloat(f[3]))
                if f[3] < 1 { m.transparency = CGFloat(f[3]) }
            }
            if let t = pbr["baseColorTexture"] as? [String: Any], let ti = t["index"] as? Int, let img = image(ti) {
                GLTFLoader.setTex(m.diffuse, img)
            }
            // металеві поверхні без повного HDR-середовища темніють — трохи обмежуємо
            m.metalness.contents = min(pbr["metallicFactor"] as? Double ?? 0.0, 0.6)
            m.roughness.contents = pbr["roughnessFactor"] as? Double ?? 0.8
        }
        if let t = d["normalTexture"] as? [String: Any], let ti = t["index"] as? Int, let img = image(ti) {
            GLTFLoader.setTex(m.normal, img)
        }
        if let t = d["emissiveTexture"] as? [String: Any], let ti = t["index"] as? Int, let img = image(ti) {
            GLTFLoader.setTex(m.emission, img)
        }
        return m
    }

    // MARK: Вузли
    private func buildNode(_ ni: Int, depth: Int = 0) throws -> SCNNode {
        let n = SCNNode()
        guard ni >= 0, ni < nodes.count, depth < 64 else { return n }
        let d = nodes[ni]
        n.name = d["name"] as? String
        if let m = d["matrix"] as? [Double], m.count == 16 {
            let f = m.map { Float($0) }
            n.simdTransform = simd_float4x4(columns: (
                SIMD4<Float>(f[0], f[1], f[2], f[3]),
                SIMD4<Float>(f[4], f[5], f[6], f[7]),
                SIMD4<Float>(f[8], f[9], f[10], f[11]),
                SIMD4<Float>(f[12], f[13], f[14], f[15])))
        } else {
            if let t = d["translation"] as? [Double], t.count == 3 {
                n.simdPosition = SIMD3<Float>(Float(t[0]), Float(t[1]), Float(t[2]))
            }
            if let r = d["rotation"] as? [Double], r.count == 4 {
                n.simdOrientation = simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3]))
            }
            if let s = d["scale"] as? [Double], s.count == 3 {
                n.simdScale = SIMD3<Float>(Float(s[0]), Float(s[1]), Float(s[2]))
            }
        }
        if let mi = d["mesh"] as? Int {
            for g in try geometries(mi) { n.addChildNode(SCNNode(geometry: g)) }
        }
        for c in d["children"] as? [Int] ?? [] { n.addChildNode(try buildNode(c, depth: depth + 1)) }
        return n
    }

    private func buildScene() throws -> SCNScene {
        let scene = SCNScene()
        var roots: [Int] = []
        let si = json["scene"] as? Int ?? 0
        if si < scenes.count, let ns = scenes[si]["nodes"] as? [Int] {
            roots = ns
        } else {
            var child = Set<Int>()
            for n in nodes { for c in n["children"] as? [Int] ?? [] { child.insert(c) } }
            roots = (0..<nodes.count).filter { !child.contains($0) }
        }
        for r in roots { scene.rootNode.addChildNode(try buildNode(r)) }
        if scene.rootNode.childNodes.isEmpty { throw GLTFError(message: "У моделі немає геометрії.") }
        return scene
    }
}
