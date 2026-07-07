import SceneKit
import UIKit
import simd

/// A die's renderable geometry plus the metadata needed to read a rolled
/// value back out of its physical resting orientation.
struct DieMesh {
    let geometry: SCNGeometry
    /// One unit normal per logical face, in the die's local space,
    /// index-aligned with `faceValues`.
    let faceNormals: [simd_float3]
    let faceValues: [Int]
    /// d4 is read from the face resting on the table, not the top face.
    let readsBottomFace: Bool
}

enum DieMeshFactory {
    private static var cache: [DieType: DieMesh] = [:]

    static func mesh(for type: DieType) -> DieMesh {
        if let cached = cache[type] { return cached }
        let built = build(type)
        cache[type] = built
        return built
    }

    // MARK: - Per-type construction

    /// Loads visual geometry from the USD model file if available in the bundle,
    /// then pairs it with procedurally-computed face normals for value reading.
    private static func build(_ type: DieType) -> DieMesh {
        let meta = buildMeta(type)
        if let geo = loadUSDA(for: type) {
            return DieMesh(geometry: geo, faceNormals: meta.faceNormals,
                          faceValues: meta.faceValues, readsBottomFace: meta.readsBottomFace)
        }
        return meta
    }

    /// Tries to load the compiled USD model from the app bundle. The
    /// DiceModels/ folder is a file-system-synchronized group, so Xcode
    /// flattens its contents to the bundle root rather than preserving the
    /// subdirectory — look it up there.
    private static func loadUSDA(for type: DieType) -> SCNGeometry? {
        let name: String
        switch type {
        case .coin:  name = "coin"
        case .d4:    name = "d4"
        case .d6:    name = "d6"
        case .d8:    name = "d8"
        case .d10:   name = "d10"
        case .d20:   name = "d20"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "usda"),
              let scene = try? SCNScene(url: url, options: nil) else { return nil }
        var found: SCNGeometry?
        scene.rootNode.enumerateChildNodes { node, stop in
            if found == nil, let geo = node.geometry {
                found = geo
                stop.pointee = true
            }
        }
        return found
    }

    /// Builds a DieMesh entirely from procedural geometry + textures.
    /// Always matches the USD geometry layout so face-normal indices stay correct.
    private static func buildMeta(_ type: DieType) -> DieMesh {
        switch type {
        case .coin: return coin()
        case .d6: return cube()
        case .d4:
            let s: Float = 1 / sqrt(3)
            let verts: [simd_float3] = [
                .init(1, 1, 1), .init(1, -1, -1), .init(-1, 1, -1), .init(-1, -1, 1)
            ].map { $0 * s }
            let faces = [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]]
            // Each face is painted with its own number (not a shared
            // vertex-read like a real tabletop d4), so the value the
            // player sees facing up is the value that should be scored —
            // read the top face like every other die, not the hidden
            // bottom one.
            return polyhedron(type, vertices: verts, faces: faces,
                              values: Array(1...4), scale: 0.78, readsBottom: false)
        case .d8:
            let verts: [simd_float3] = [
                .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0),
                .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1)
            ]
            let faces = [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4],
                         [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
            return polyhedron(type, vertices: verts, faces: faces,
                              values: Array(1...8), scale: 0.68, readsBottom: false)
        case .d10:
            let (verts, faces) = trapezohedron()
            return polyhedron(type, vertices: verts, faces: faces,
                              values: Array(1...10), scale: 0.66, readsBottom: false)
        case .d20:
            let (verts, faces) = icosahedron()
            return polyhedron(type, vertices: verts, faces: faces,
                              values: Array(1...20), scale: 0.72, readsBottom: false)
        }
    }

    // MARK: - d6 (textured box with pips)

    private static func cube() -> DieMesh {
        let box = SCNBox(width: 0.8, height: 0.8, length: 0.8, chamferRadius: 0.07)
        // SCNBox material order: front(+z), right(+x), back(-z), left(-x), top(+y), bottom(-y).
        // Opposite faces of a d6 sum to 7.
        let values = [1, 2, 6, 5, 3, 4]
        box.materials = values.map { material(image: pipImage(value: $0)) }
        let normals: [simd_float3] = [
            .init(0, 0, 1), .init(1, 0, 0), .init(0, 0, -1),
            .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0)
        ]
        return DieMesh(geometry: box, faceNormals: normals, faceValues: values, readsBottomFace: false)
    }

    // MARK: - Coin (cylinder, 0/I faces - golden)

    private static func coin() -> DieMesh {
        let cyl = SCNCylinder(radius: 0.5, height: 0.11)
        let edge = SCNMaterial()
        edge.diffuse.contents = UIColor(hex: 0xD4AF37)
        edge.metalness.contents = 0.9
        edge.roughness.contents = 0.3
        edge.lightingModel = .physicallyBased
        // SCNCylinder material order: side, top, bottom.
        cyl.materials = [
            edge,
            material(image: coinFaceImage(letter: "0")),
            material(image: coinFaceImage(letter: "I"))
        ]
        return DieMesh(
            geometry: cyl,
            faceNormals: [.init(0, 1, 0), .init(0, -1, 0)],
            faceValues: [0, 1],
            readsBottomFace: false
        )
    }

    // MARK: - Generic polyhedron builder

    /// Builds flat-shaded geometry with one element + material per face so each
    /// face can carry its own number texture, and records per-face normals.
    private static func polyhedron(_ type: DieType,
                                   vertices: [simd_float3],
                                   faces: [[Int]],
                                   values: [Int],
                                   scale: Float,
                                   readsBottom: Bool) -> DieMesh {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        var faceNormals: [simd_float3] = []

        for (faceIndex, face) in faces.enumerated() {
            var pts = face.map { vertices[$0] * scale }
            let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
            var n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
            if simd_dot(n, center) < 0 { pts.reverse(); n = -n }
            faceNormals.append(n)

            // Face-local 2D basis for texture coordinates.
            let u = simd_normalize(pts[0] - center)
            let v = simd_cross(n, u)
            let projected = pts.map { p in
                simd_float2(simd_dot(p - center, u), simd_dot(p - center, v))
            }
            let maxRadius = projected.map { simd_length($0) }.max() ?? 1

            let base = positions.count
            for (i, p) in pts.enumerated() {
                positions.append(SCNVector3(p.x, p.y, p.z))
                normals.append(SCNVector3(n.x, n.y, n.z))
                uvs.append(CGPoint(
                    x: CGFloat(0.5 + projected[i].x / (2.15 * maxRadius)),
                    y: CGFloat(0.5 - projected[i].y / (2.15 * maxRadius))
                ))
            }

            // Triangle fan over the (convex) face.
            var indices: [Int32] = []
            for i in 1..<(pts.count - 1) {
                indices += [Int32(base), Int32(base + i), Int32(base + i + 1)]
            }
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))

            materials.append(material(image: numberImage(text: String(values[faceIndex]), type: type)))
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs)
            ],
            elements: elements
        )
        geometry.materials = materials
        return DieMesh(geometry: geometry, faceNormals: faceNormals,
                       faceValues: values, readsBottomFace: readsBottom)
    }

    // MARK: - Vertex sets

    /// Pentagonal dipyramid (d10): 5 faces pointing up, 5 pointing down.
    private static func trapezohedron() -> ([simd_float3], [[Int]]) {
        var verts: [simd_float3] = [
            .init(0, 0.92, 0),   // 0: top apex
            .init(0, -0.92, 0)   // 1: bottom apex
        ]
        // Equatorial ring: 5 vertices of a regular pentagon at y=0.
        for k in 0..<5 {
            let a = Float(k) * .pi * 2 / 5
            verts.append(.init(cos(a), 0, sin(a)))
        }
        var faces: [[Int]] = []
        let ring = { (k: Int) in 2 + ((k % 5) + 5) % 5 }
        // Upper cone: 5 triangles from top apex to consecutive equatorial pairs.
        for k in 0..<5 {
            faces.append([0, ring(k), ring(k + 1)])
        }
        // Lower cone: 5 triangles from bottom apex to consecutive equatorial pairs (reversed).
        for k in 0..<5 {
            faces.append([1, ring(k + 1), ring(k)])
        }
        return (verts, faces)
    }

    /// Regular icosahedron (d20): faces derived from edge adjacency.
    private static func icosahedron() -> ([simd_float3], [[Int]]) {
        let phi = Float((1 + sqrt(5.0)) / 2)
        var verts: [simd_float3] = []
        for s1 in [Float(1), -1] {
            for s2 in [Float(phi), -phi] {
                verts.append(.init(0, s1, s2))
                verts.append(.init(s1, s2, 0))
                verts.append(.init(s2, 0, s1))
            }
        }
        let norm = simd_length(verts[0])
        verts = verts.map { $0 / norm }

        // Edge length of the unit-circumradius icosahedron.
        let edge = 2 / norm
        var faces: [[Int]] = []
        let count = verts.count
        for i in 0..<count {
            for j in (i + 1)..<count where isEdge(verts[i], verts[j], edge) {
                for k in (j + 1)..<count
                where isEdge(verts[j], verts[k], edge) && isEdge(verts[i], verts[k], edge) {
                    faces.append([i, j, k])
                }
            }
        }
        return (verts, faces)
    }

    private static func isEdge(_ a: simd_float3, _ b: simd_float3, _ edge: Float) -> Bool {
        abs(simd_distance(a, b) - edge) < 0.01
    }

    // MARK: - Face textures

    private static func material(image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.38
        m.metalness.contents = 0.0
        return m
    }

    private static func roundedFont(size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = system.fontDescriptor.withDesign(.rounded) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static var materialImageCache: [String: UIImage] = [:]

    private static func loadMaterialImage(_ name: String) -> UIImage? {
        if let cached = materialImageCache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        materialImageCache[name] = image
        return image
    }

    /// Dark inlay plate behind numbers/pips so they read clearly over busy
    /// material photos — enamel-inlay look rather than text floating on a photo.
    private static func drawInlayPlate(_ rect: CGRect, in ctx: CGContext) {
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.22)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
    }

    private static let inlayTextColor = UIColor(hex: 0xF2E7CC)  // cream, reads on the dark plate

    /// Draws the photographed material aspect-filled into the tile, with a
    /// soft sheen/vignette pass for depth. Falls back to a flat color fill
    /// if the material photo isn't bundled for some reason.
    private static func faceBackground(materialName: String, fallback: UIColor, in ctx: CGContext, size: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        if let image = loadMaterialImage(materialName), let cgImage = image.cgImage {
            let imgSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            let scale = max(size / imgSize.width, size / imgSize.height)
            let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
            let origin = CGPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(cgImage, in: CGRect(origin: origin, size: drawSize))
            ctx.restoreGState()
        } else {
            fallback.setFill()
            ctx.fill(rect)
        }
        // Soft highlight toward one corner, vignette at edges.
        let colors = [UIColor.white.withAlphaComponent(0.14).cgColor,
                      UIColor.clear.cgColor,
                      UIColor.black.withAlphaComponent(0.24).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: .zero,
                                   end: CGPoint(x: size, y: size),
                                   options: [])
        }
    }

    private static func numberImage(text: String, type: DieType) -> UIImage {
        let size: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            faceBackground(materialName: type.materialImageName, fallback: type.uiAccent,
                           in: context.cgContext, size: size)
            let plate = CGRect(x: size * 0.28, y: size * 0.28, width: size * 0.44, height: size * 0.44)
            drawInlayPlate(plate, in: context.cgContext)
            let fontSize: CGFloat = text.count > 2 ? 64 : 84
            let attrs: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size: fontSize),
                .foregroundColor: inlayTextColor
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let bounds = str.boundingRect(with: CGSize(width: size, height: size),
                                          options: .usesLineFragmentOrigin, context: nil)
            str.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        }
    }

    private static func pipImage(value: Int) -> UIImage {
        let size: CGFloat = 256
        let layouts: [Int: [(CGFloat, CGFloat)]] = [
            1: [(0.5, 0.5)],
            2: [(0.28, 0.25), (0.72, 0.75)],
            3: [(0.28, 0.25), (0.5, 0.5), (0.72, 0.75)],
            4: [(0.28, 0.25), (0.72, 0.25), (0.28, 0.75), (0.72, 0.75)],
            5: [(0.28, 0.25), (0.72, 0.25), (0.5, 0.5), (0.28, 0.75), (0.72, 0.75)],
            6: [(0.28, 0.24), (0.28, 0.5), (0.28, 0.76), (0.72, 0.24), (0.72, 0.5), (0.72, 0.76)]
        ]
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            faceBackground(materialName: DieType.d6.materialImageName, fallback: DieType.d6.uiAccent,
                           in: context.cgContext, size: size)
            let plate = CGRect(x: size * 0.16, y: size * 0.16, width: size * 0.68, height: size * 0.68)
            drawInlayPlate(plate, in: context.cgContext)
            inlayTextColor.setFill()
            let radius: CGFloat = 22
            for (x, y) in layouts[value] ?? [] {
                let rect = CGRect(x: x * size - radius, y: y * size - radius,
                                  width: radius * 2, height: radius * 2)
                context.cgContext.fillEllipse(in: rect)
            }
        }
    }

    private static func coinFaceImage(letter: String) -> UIImage {
        let size: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let ctx = context.cgContext
            faceBackground(materialName: DieType.coin.materialImageName, fallback: UIColor(hex: 0xD4AF37),
                           in: ctx, size: size)
            // Rim ring.
            ctx.setStrokeColor(UIColor(hex: 0x8B6914).withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(10)
            ctx.strokeEllipse(in: CGRect(x: 10, y: 10, width: size - 20, height: size - 20))
            // Embossed inlay circle behind the letter.
            let emboss = CGRect(x: size * 0.3, y: size * 0.3, width: size * 0.4, height: size * 0.4)
            drawInlayPlate(emboss, in: ctx)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size: 64),
                .foregroundColor: inlayTextColor
            ]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let bounds = str.boundingRect(with: CGSize(width: size, height: size),
                                          options: .usesLineFragmentOrigin, context: nil)
            str.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        }
    }
}
