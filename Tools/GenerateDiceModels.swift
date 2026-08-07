#!/usr/bin/swift
//
//  GenerateDiceModels.swift
//  Dice Throw asset pipeline
//
//  Generates one USD model file (<die>.usda) plus a texture atlas
//  (<die>_diffuse.png) for every die type. The .usda files open in
//  Reality Composer Pro and are loaded by the app at runtime via ModelIO.
//
//  The polyhedron math here MUST stay in sync with
//  DiceThrow/Game/DiceGeometry.swift — the app reads rolled values from
//  face orientations using the same vertex/face tables.
//
//  Usage: swift Tools/GenerateDiceModels.swift DiceThrow/Resources/DiceModels
//

import AppKit
import simd

// MARK: - Shared math (mirror of DiceGeometry.swift)

let phi = Float((1 + sqrt(5.0)) / 2)

func tetrahedron() -> ([simd_float3], [[Int]]) {
    let s: Float = 1 / sqrt(3)
    let verts: [simd_float3] = [
        .init(1, 1, 1), .init(1, -1, -1), .init(-1, 1, -1), .init(-1, -1, 1)
    ].map { $0 * s }
    return (verts, [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]])
}

func octahedron() -> ([simd_float3], [[Int]]) {
    let verts: [simd_float3] = [
        .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0),
        .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1)
    ]
    let faces = [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4],
                 [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
    return (verts, faces)
}

func trapezohedron() -> ([simd_float3], [[Int]]) {
    var verts: [simd_float3] = [.init(0, 0.92, 0), .init(0, -0.92, 0)]
    for k in 0..<5 {
        let a = Float(k) * .pi * 2 / 5
        verts.append(.init(cos(a), 0, sin(a)))
    }
    var faces: [[Int]] = []
    let ring = { (k: Int) in 2 + ((k % 5) + 5) % 5 }
    // Upper cone: 5 triangles from top apex to consecutive equatorial pairs
    for k in 0..<5 {
        faces.append([0, ring(k), ring(k + 1)])
    }
    // Lower cone: 5 triangles from bottom apex to consecutive equatorial pairs (reversed)
    for k in 0..<5 {
        faces.append([1, ring(k + 1), ring(k)])
    }
    return (verts, faces)
}

func icosahedron() -> ([simd_float3], [[Int]]) {
    var verts: [simd_float3] = []
    for s1 in [Float(1), -1] {
        for s2 in [phi, -phi] {
            verts.append(.init(0, s1, s2))
            verts.append(.init(s1, s2, 0))
            verts.append(.init(s2, 0, s1))
        }
    }
    let norm = simd_length(verts[0])
    verts = verts.map { $0 / norm }
    let edge = 2 / norm
    func isEdge(_ a: simd_float3, _ b: simd_float3) -> Bool {
        abs(simd_distance(a, b) - edge) < 0.01
    }
    var faces: [[Int]] = []
    for i in 0..<verts.count {
        for j in (i + 1)..<verts.count where isEdge(verts[i], verts[j]) {
            for k in (j + 1)..<verts.count
            where isEdge(verts[j], verts[k]) && isEdge(verts[i], verts[k]) {
                faces.append([i, j, k])
            }
        }
    }
    return (verts, faces)
}

func dodecahedron() -> ([simd_float3], [[Int]]) {
    var verts: [simd_float3] = []
    for x in [Float(1), -1] {
        for y in [Float(1), -1] {
            for z in [Float(1), -1] { verts.append(.init(x, y, z)) }
        }
    }
    for s1 in [Float(1), -1] {
        for s2 in [phi, -phi] {
            verts.append(.init(0, s1 / phi, s2))
            verts.append(.init(s1 / phi, s2, 0))
            verts.append(.init(s2, 0, s1 / phi))
        }
    }
    let norm = simd_length(verts[0])
    verts = verts.map { $0 / norm }
    // The 12 face normals are the dual icosahedron's vertices, and only one of the
    // three cyclic phases is actually dual to the vertex set built above. Using the
    // wrong phase makes `prefix(5)` below pick five non-coplanar vertices — the
    // pentagons come out warped and bevelPolyhedron then drops every edge band and
    // corner cap. Correct phase: exactly five vertices tie for the top dot product.
    var faceDirs: [simd_float3] = []
    for s1 in [Float(1), -1] {
        for s2 in [phi, -phi] {
            faceDirs.append(simd_normalize(.init(s1, 0, s2)))
            faceDirs.append(simd_normalize(.init(s2, s1, 0)))
            faceDirs.append(simd_normalize(.init(0, s2, s1)))
        }
    }
    var faces: [[Int]] = []
    for dir in faceDirs {
        let ranked = verts.indices.sorted { simd_dot(verts[$0], dir) > simd_dot(verts[$1], dir) }
        var pentagon = Array(ranked.prefix(5))
        let axisU = simd_normalize(verts[pentagon[0]] - dir * simd_dot(verts[pentagon[0]], dir))
        let axisV = simd_cross(dir, axisU)
        pentagon.sort {
            let a = verts[$0], b = verts[$1]
            return atan2(simd_dot(a, axisV), simd_dot(a, axisU))
                 < atan2(simd_dot(b, axisV), simd_dot(b, axisU))
        }
        faces.append(pentagon)
    }
    return (verts, faces)
}

func cube(half: Float) -> ([simd_float3], [[Int]]) {
    var verts: [simd_float3] = []
    for x in [Float(-1), 1] {
        for y in [Float(-1), 1] {
            for z in [Float(-1), 1] { verts.append(.init(x, y, z) * half) }
        }
    }
    // idx = x*4 + y*2 + z with -1→0, 1→1
    // Face order matches DiceGeometry: +z, +x, -z, -x, +y, -y.
    let faces = [
        [1, 3, 7, 5],   // +z
        [4, 5, 7, 6],   // +x
        [0, 2, 6, 4],   // -z
        [0, 1, 3, 2],   // -x
        [2, 3, 7, 6],   // +y
        [0, 1, 5, 4]    // -y
    ]
    return (verts, faces)
}

// MARK: - Tile artwork

enum TileArt {
    case number(String)
    case pips(Int)
    case d4Corners([Int])       // vertex values at the face's three corners
    case coinLetter(String)
    case coinEdge
}

struct DieSpec {
    let name: String
    let baseColor: UInt32       // matches DieType accents in Models.swift
    let scale: Float
    let metallic: Bool
    let mesh: ([simd_float3], [[Int]])
    let tiles: [TileArt]        // one per face, index-aligned
    let materialImageName: String  // photographed material tile, e.g. "mat_marble_white"
}

/// Loads a photographed material tile (already sitting in outDir — see
/// Tools/GenerateBoxModel-style asset placement) for use as a face background.
func materialImage(_ name: String, outDir: URL) -> NSImage? {
    NSImage(contentsOf: outDir.appendingPathComponent("\(name).png"))
}

/// Draws `image` aspect-filled into `rect`, cropping the excess so it isn't
/// stretched.
func drawAspectFill(_ image: NSImage, in rect: CGRect) {
    let imgSize = image.size
    guard imgSize.width > 0, imgSize.height > 0 else { return }
    let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
    let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
    let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    image.draw(in: CGRect(origin: origin, size: drawSize),
               from: .zero, operation: .sourceOver, fraction: 1)
}

/// Dark inlay plate behind numbers/pips so they stay legible over busy
/// material photos (marble veining, wood grain, rust) — reads like enamel
/// inlay on the material rather than text floating over a photo.
func drawInlayPlate(rect: CGRect, ctx: CGContext) {
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.22,
                      cornerHeight: rect.height * 0.22, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

func nscolor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func lighter(_ hex: UInt32, _ f: CGFloat) -> NSColor {
    let c = nscolor(hex)
    return NSColor(calibratedRed: min(1, c.redComponent + f),
                   green: min(1, c.greenComponent + f),
                   blue: min(1, c.blueComponent + f), alpha: 1)
}

func darker(_ hex: UInt32, _ f: CGFloat) -> NSColor {
    let c = nscolor(hex)
    return NSColor(calibratedRed: max(0, c.redComponent - f),
                   green: max(0, c.greenComponent - f),
                   blue: max(0, c.blueComponent - f), alpha: 1)
}

func roundedFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .bold)
    if let desc = base.fontDescriptor.withDesign(.rounded),
       let font = NSFont(descriptor: desc, size: size) {
        return font
    }
    return base
}

func drawCenteredText(_ text: String, at center: CGPoint, size: CGFloat,
                      color: NSColor, rotation: CGFloat = 0) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(size),
        .foregroundColor: color
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.boundingRect(with: .zero, options: .usesLineFragmentOrigin)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotation)
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    str.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
    ctx.restoreGState()
}

/// Corner positions (unit tile space) each tile's face polygon corners map to.
/// Mirrors the UV projection below so numbers land on the right spots.
func projectedCorners(face: [Int], verts: [simd_float3]) -> [simd_float2] {
    projectedCorners(points: face.map { verts[$0] })
}

func projectedCorners(points: [simd_float3]) -> [simd_float2] {
    var pts = points
    let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
    var n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
    if simd_dot(n, center) < 0 { pts.reverse(); n = -n }
    // Even-sided faces take their basis from an edge midpoint, odd-sided ones from a
    // vertex. Pointing `u` at a vertex puts a square's corners on the ±u/±v axes — a
    // diamond in tile space — which rotated every d6 face's pips 45° and clipped the
    // inlay plate. Triangles keep the vertex basis so the d4's corner numbers, which
    // index the projected corners directly, stay put; pentagons carry centred numbers
    // either way.
    let u = pts.count % 2 == 0
        ? simd_normalize((pts[0] + pts[1]) * 0.5 - center)
        : simd_normalize(pts[0] - center)
    let v = simd_cross(n, u)
    let projected = pts.map { p in simd_float2(simd_dot(p - center, u), simd_dot(p - center, v)) }
    let maxR = projected.map { simd_length($0) }.max() ?? 1
    return projected.map { $0 / maxR }   // in [-1, 1]
}

// MARK: - Beveling (rounded/cut corners like a real die)

/// A convex polyhedron with each face inset toward its own centroid, and the
/// resulting gaps at edges and vertices filled with flat facets — "cut
/// corners" like a real die. `originalFaces` keeps the same order/count as
/// the input `faces` (for face-value reading + pip/number art); `bevelFaces`
/// are the new edge-band and corner-cap facets (plain material, no text).
struct BeveledMesh {
    var vertices: [simd_float3] = []
    var originalFaces: [[Int]] = []
    var bevelFaces: [[Int]] = []
}

func bevelPolyhedron(vertices: [simd_float3], faces rawFaces: [[Int]], insetFactor: Float) -> BeveledMesh {
    var result = BeveledMesh()

    // Normalize winding so every face points outward — required for shared
    // edges to appear in strictly opposite order between neighboring faces,
    // which the edge/corner adjacency logic below depends on.
    let faces: [[Int]] = rawFaces.map { face in
        let pts = face.map { vertices[$0] }
        let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
        let n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
        return simd_dot(n, center) < 0 ? face.reversed() : face
    }

    // Each face gets its own shrunk copy of its vertices (toward its centroid).
    var faceVertexIndex: [[Int]] = []
    for face in faces {
        let pts = face.map { vertices[$0] }
        let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
        var localIndices: [Int] = []
        for p in pts {
            localIndices.append(result.vertices.count)
            result.vertices.append(center + (p - center) * insetFactor)
        }
        faceVertexIndex.append(localIndices)
    }
    result.originalFaces = faceVertexIndex

    // Map each undirected original edge to its two face occurrences.
    struct EdgeOcc { let faceIdx: Int; let localA: Int; let localB: Int }
    func edgeKey(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
    var edgeMap: [Int64: [EdgeOcc]] = [:]
    for (fi, face) in faces.enumerated() {
        let n = face.count
        for i in 0..<n {
            let a = face[i], b = face[(i + 1) % n]
            edgeMap[edgeKey(a, b), default: []].append(EdgeOcc(faceIdx: fi, localA: i, localB: (i + 1) % n))
        }
    }

    // Edge bevel bands: a flat quad connecting each edge's two shrunk copies.
    for (_, occs) in edgeMap {
        guard occs.count == 2 else { continue }
        let o1 = occs[0], o2 = occs[1]
        let a1 = faceVertexIndex[o1.faceIdx][o1.localA]
        let b1 = faceVertexIndex[o1.faceIdx][o1.localB]
        let a2 = faceVertexIndex[o2.faceIdx][o2.localA]
        let b2 = faceVertexIndex[o2.faceIdx][o2.localB]
        result.bevelFaces.append([a1, b1, a2, b2])
    }

    // Corner caps: at each original vertex, chain the adjacent faces in
    // cyclic order (via shared outgoing edges) and connect their shrunk
    // copies of that vertex into a small polygon.
    for v in 0..<vertices.count {
        var occurrences: [(faceIdx: Int, localIdx: Int)] = []
        for (fi, face) in faces.enumerated() {
            if let li = face.firstIndex(of: v) { occurrences.append((fi, li)) }
        }
        guard occurrences.count >= 3 else { continue }

        var ordered = [occurrences[0]]
        var remaining = Set(1..<occurrences.count)
        while ordered.count < occurrences.count {
            let current = ordered.last!
            let face = faces[current.faceIdx]
            let n = face.count
            let nextVertexOrig = face[(current.localIdx + 1) % n]
            guard let foundIdx = remaining.first(where: { idx in
                let f = faces[occurrences[idx].faceIdx]
                let m = f.count
                return f[(occurrences[idx].localIdx - 1 + m) % m] == nextVertexOrig
            }) else { break }
            ordered.append(occurrences[foundIdx])
            remaining.remove(foundIdx)
        }
        guard ordered.count == occurrences.count else { continue }  // non-manifold edge case, skip

        result.bevelFaces.append(ordered.map { faceVertexIndex[$0.faceIdx][$0.localIdx] })
    }

    return result
}

func drawTile(_ art: TileArt, rect: CGRect, spec: DieSpec,
              corners: [simd_float2], materialImg: NSImage?) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let insetScale: CGFloat = 0.42     // matches the UV mapping below
    let pipColor = nscolor(0xF2E7CC)   // cream inlay, reads clearly on the dark plate

    switch art {
    case .coinLetter(let letter):
        if let materialImg { drawAspectFill(materialImg, in: rect) } else {
            nscolor(0xD4AF37).setFill(); ctx.fill(rect)
        }
        // Subtle polish sheen over the photo, then rim + embossed center.
        let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18),
                                        NSColor.clear,
                                        NSColor.black.withAlphaComponent(0.12)],
                               atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
        sheen.draw(in: rect, angle: -55)
        ctx.setStrokeColor(nscolor(0x8B6914).withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(rect.width * 0.045)
        let rim = rect.insetBy(dx: rect.width * (0.5 - insetScale), dy: rect.height * (0.5 - insetScale))
        ctx.strokeEllipse(in: rim)
        let emboss = rect.insetBy(dx: rect.width * 0.33, dy: rect.height * 0.33)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fillEllipse(in: emboss)
        drawCenteredText(letter, at: CGPoint(x: rect.midX, y: rect.midY),
                         size: rect.width * 0.24, color: pipColor)

    case .coinEdge:
        if let materialImg {
            // Tile the material photo twice across the edge strip.
            let half = CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
            drawAspectFill(materialImg, in: half)
            drawAspectFill(materialImg, in: half.offsetBy(dx: rect.width / 2, dy: 0))
        } else {
            nscolor(0xD4AF37).setFill(); ctx.fill(rect)
        }

    default:
        // Real photographed material as the face background.
        if let materialImg {
            drawAspectFill(materialImg, in: rect)
            let vignette = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10),
                                               NSColor.clear,
                                               NSColor.black.withAlphaComponent(0.22)],
                                      atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
            vignette.draw(in: rect, angle: -55)
        } else {
            nscolor(spec.baseColor).setFill()
            ctx.fill(rect)
            let sheen = NSGradient(colors: [lighter(spec.baseColor, 0.16),
                                            nscolor(spec.baseColor),
                                            darker(spec.baseColor, 0.14)],
                                   atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
            sheen.draw(in: rect, angle: -55)
        }

        switch art {
        case .number(let text):
            let plate = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)
            drawInlayPlate(rect: plate, ctx: ctx)
            // A lone 6 and a lone 9 are the same glyph upside down, and on a die
            // that lands in any orientation there is nothing else to tell them
            // apart — so mark them the way real dice do. Only single digits: on
            // 16 or 19 the leading digit already fixes the reading.
            let label = (text == "6" || text == "9") ? text + "." : text
            let size: CGFloat = label.count > 2 ? rect.width * 0.26 : rect.width * 0.34
            drawCenteredText(label, at: CGPoint(x: rect.midX, y: rect.midY),
                             size: size, color: pipColor)
        case .pips(let value):
            let plate = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
            drawInlayPlate(rect: plate, ctx: ctx)
            let layouts: [Int: [(CGFloat, CGFloat)]] = [
                1: [(0.5, 0.5)],
                2: [(0.3, 0.7), (0.7, 0.3)],
                3: [(0.3, 0.7), (0.5, 0.5), (0.7, 0.3)],
                4: [(0.3, 0.3), (0.3, 0.7), (0.7, 0.3), (0.7, 0.7)],
                5: [(0.3, 0.3), (0.3, 0.7), (0.5, 0.5), (0.7, 0.3), (0.7, 0.7)],
                6: [(0.3, 0.28), (0.3, 0.5), (0.3, 0.72), (0.7, 0.28), (0.7, 0.5), (0.7, 0.72)]
            ]
            pipColor.setFill()
            let r = rect.width * 0.052
            for (fx, fy) in layouts[value] ?? [] {
                // Pips live inside the projected face square (inset like the UV map).
                let px = rect.midX + (fx - 0.5) * 2 * insetScale * rect.width
                let py = rect.midY + (fy - 0.5) * 2 * insetScale * rect.height
                ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
            }
        case .d4Corners(let values):
            // Real d4s label each corner with that vertex's value, rotated
            // to read outward — the top vertex's number is the roll.
            for (i, value) in values.enumerated() {
                let c = corners[i]
                let cx = rect.midX + CGFloat(c.x) * insetScale * rect.width * 0.62
                let cy = rect.midY + CGFloat(c.y) * insetScale * rect.height * 0.62
                let angle = atan2(CGFloat(c.y), CGFloat(c.x)) - .pi / 2
                let plateSize = rect.width * 0.22
                drawInlayPlate(rect: CGRect(x: cx - plateSize / 2, y: cy - plateSize / 2,
                                            width: plateSize, height: plateSize), ctx: ctx)
                drawCenteredText("\(value)", at: CGPoint(x: cx, y: cy),
                                 size: rect.width * 0.17, color: pipColor, rotation: angle)
            }
        default:
            break
        }
    }
}

/// Plain material sample for bevel facets (edge bands + corner caps) — same
/// photo, no pips/numbers, slightly darkened so the cut edges read as a
/// distinct beveled surface catching less light.
func drawBevelTile(rect: CGRect, materialImg: NSImage?, fallbackColor: UInt32) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    if let materialImg {
        drawAspectFill(materialImg, in: rect)
    } else {
        nscolor(fallbackColor).setFill()
        ctx.fill(rect)
    }
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.fill(rect)
}

// MARK: - Atlas + USD generation

struct GeneratedMesh {
    var counts: [Int] = []
    var indices: [Int] = []
    var points: [simd_float3] = []
    var normals: [simd_float3] = []    // faceVarying
    var st: [simd_float2] = []         // faceVarying
}

func fmt(_ v: Float) -> String { String(format: "%.5g", v) }

func generate(spec: DieSpec, outDir: URL) throws {
    let materialImg = materialImage(spec.materialImageName, outDir: outDir)
    let (rawVerts, faces) = spec.mesh
    let verts = rawVerts.map { $0 * spec.scale }

    // Bevel: shrink each face toward its own centroid, fill the resulting
    // edge/corner gaps with flat facets — "cut corners" like a real die.
    let bevel = bevelPolyhedron(vertices: verts, faces: faces, insetFactor: 0.88)

    let faceCount = faces.count
    let totalTiles = faceCount + 1  // +1 shared tile for every bevel facet
    let cols = Int(ceil(sqrt(Double(totalTiles))))
    let rows = Int(ceil(Double(totalTiles) / Double(cols)))
    let tile: CGFloat = 256
    let atlasW = CGFloat(cols) * tile
    let atlasH = CGFloat(rows) * tile

    // --- Texture atlas ---
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(atlasW),
                               pixelsHigh: Int(atlasH), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    var mesh = GeneratedMesh()

    func tileRect(_ index: Int) -> CGRect {
        let col = index % cols
        let row = index / cols
        return CGRect(x: CGFloat(col) * tile, y: atlasH - CGFloat(row + 1) * tile, width: tile, height: tile)
    }
    func tileUV(_ index: Int, corner c: simd_float2) -> simd_float2 {
        let col = index % cols
        let row = index / cols
        let u = (CGFloat(col) + 0.5 + CGFloat(c.x) * 0.42) / CGFloat(cols)
        let v = (CGFloat(rows - 1 - row) + 0.5 + CGFloat(c.y) * 0.42) / CGFloat(rows)
        return simd_float2(Float(u), Float(v))
    }
    func appendFace(_ indices: [Int], normal: simd_float3, tileIndex: Int, corners: [simd_float2]) {
        mesh.counts.append(indices.count)
        for (ci, vi) in indices.enumerated() {
            mesh.points.append(bevel.vertices[vi])
            mesh.indices.append(mesh.points.count - 1)
            mesh.normals.append(normal)
            mesh.st.append(tileUV(tileIndex, corner: corners[ci]))
        }
    }

    // Original (bevel-shrunk) faces — keep their pips/numbers, same order as
    // `faces` so face-value reading in DiceGeometry.swift stays untouched.
    for (fi, faceIdx) in bevel.originalFaces.enumerated() {
        var orderedIdx = faceIdx
        var pts = orderedIdx.map { bevel.vertices[$0] }
        let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
        var n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
        if simd_dot(n, center) < 0 {
            orderedIdx.reverse(); pts.reverse(); n = -n
        }
        let corners = projectedCorners(points: pts)
        drawTile(spec.tiles[fi], rect: tileRect(fi), spec: spec, corners: corners, materialImg: materialImg)
        appendFace(orderedIdx, normal: n, tileIndex: fi, corners: corners)
    }

    // Bevel facets (edge bands + corner caps) — plain shared material tile.
    let bevelTileIndex = faceCount
    drawBevelTile(rect: tileRect(bevelTileIndex), materialImg: materialImg, fallbackColor: spec.baseColor)
    for faceIdx in bevel.bevelFaces {
        var orderedIdx = faceIdx
        var pts = orderedIdx.map { bevel.vertices[$0] }
        let center = pts.reduce(simd_float3.zero, +) / Float(pts.count)
        var n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
        if simd_dot(n, center) < 0 {
            orderedIdx.reverse(); pts.reverse(); n = -n
        }
        let corners = projectedCorners(points: pts)
        appendFace(orderedIdx, normal: n, tileIndex: bevelTileIndex, corners: corners)
    }

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(spec.name)_diffuse.png"))

    try writeUSDA(spec: spec, mesh: mesh, outDir: outDir)
}

/// Coin gets a bespoke cylinder mesh: cap fans + side quads.
func generateCoin(outDir: URL) throws {
    let name = "coin"
    let radius: Float = 0.5
    let halfH: Float = 0.055
    let segments = 40

    let tile: CGFloat = 256
    let atlasW = tile * 2
    let atlasH = tile * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(atlasW),
                               pixelsHigh: Int(atlasH), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let coinSpec = DieSpec(name: name, baseColor: 0xD4AF37, scale: 1, metallic: true,
                           mesh: ([], []), tiles: [], materialImageName: "mat_gold")
    let coinMaterialImg = materialImage(coinSpec.materialImageName, outDir: outDir)
    // Tiles (AppKit bottom-left origin): 0 top-left, I top-right, edge bottom row.
    drawTile(.coinLetter("0"), rect: CGRect(x: 0, y: tile, width: tile, height: tile),
             spec: coinSpec, corners: [], materialImg: coinMaterialImg)
    drawTile(.coinLetter("I"), rect: CGRect(x: tile, y: tile, width: tile, height: tile),
             spec: coinSpec, corners: [], materialImg: coinMaterialImg)
    drawTile(.coinEdge, rect: CGRect(x: 0, y: 0, width: atlasW, height: tile),
             spec: coinSpec, corners: [], materialImg: coinMaterialImg)

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(name)_diffuse.png"))

    var mesh = GeneratedMesh()
    for ring in [halfH, -halfH] {
        for k in 0..<segments {
            let a = Float(k) / Float(segments) * 2 * .pi
            mesh.points.append(.init(cos(a) * radius, ring, sin(a) * radius))
        }
    }
    let topCenter = mesh.points.count
    mesh.points.append(.init(0, halfH, 0))
    let botCenter = mesh.points.count
    mesh.points.append(.init(0, -halfH, 0))

    // UV helpers (st origin bottom-left; atlas is 2x2 tiles).
    func capUV(tileX: Int, k: Int, isCenter: Bool) -> simd_float2 {
        if isCenter { return .init(Float(tileX) * 0.5 + 0.25, 0.75) }
        let a = Float(k % segments) / Float(segments) * 2 * .pi
        return .init(Float(tileX) * 0.5 + 0.25 + cos(a) * 0.21,
                     0.75 + sin(a) * 0.21)
    }

    // Top cap (+y): counter-clockwise seen from above.
    for k in 0..<segments {
        let k1 = (k + 1) % segments
        mesh.counts.append(3)
        mesh.indices += [topCenter, k1, k]
        mesh.normals += [simd_float3(0, 1, 0), .init(0, 1, 0), .init(0, 1, 0)]
        mesh.st += [capUV(tileX: 0, k: 0, isCenter: true),
                    capUV(tileX: 0, k: k1, isCenter: false),
                    capUV(tileX: 0, k: k, isCenter: false)]
    }
    // Bottom cap (-y).
    for k in 0..<segments {
        let k1 = (k + 1) % segments
        mesh.counts.append(3)
        mesh.indices += [botCenter, segments + k, segments + k1]
        mesh.normals += [simd_float3(0, -1, 0), .init(0, -1, 0), .init(0, -1, 0)]
        mesh.st += [capUV(tileX: 1, k: 0, isCenter: true),
                    capUV(tileX: 1, k: k, isCenter: false),
                    capUV(tileX: 1, k: k1, isCenter: false)]
    }
    // Side quads mapped across the edge strip.
    for k in 0..<segments {
        let k1 = (k + 1) % segments
        mesh.counts.append(4)
        mesh.indices += [k, k1, segments + k1, segments + k]
        let n0 = simd_normalize(simd_float3(mesh.points[k].x, 0, mesh.points[k].z))
        let n1 = simd_normalize(simd_float3(mesh.points[k1].x, 0, mesh.points[k1].z))
        mesh.normals += [n0, n1, n1, n0]
        let u0 = Float(k) / Float(segments)
        let u1 = Float(k + 1) / Float(segments)
        mesh.st += [.init(u0, 0.42), .init(u1, 0.42), .init(u1, 0.08), .init(u0, 0.08)]
    }

    try writeUSDA(spec: coinSpec, mesh: mesh, outDir: outDir)
}

func writeUSDA(spec: DieSpec, mesh: GeneratedMesh, outDir: URL) throws {
    let prim = spec.name.capitalized
    var s = """
    #usda 1.0
    (
        defaultPrim = "\(prim)"
        metersPerUnit = 1
        upAxis = "Y"
        doc = "Dice Throw – \(spec.name) die. Generated by Tools/GenerateDiceModels.swift; open in Reality Composer Pro."
    )

    def Xform "\(prim)" (
        kind = "component"
    )
    {
        def Mesh "Geometry"
        {
            int[] faceVertexCounts = [\(mesh.counts.map(String.init).joined(separator: ", "))]
            int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]
            point3f[] points = [\(mesh.points.map { "(\(fmt($0.x)), \(fmt($0.y)), \(fmt($0.z)))" }.joined(separator: ", "))]
            normal3f[] normals = [\(mesh.normals.map { "(\(fmt($0.x)), \(fmt($0.y)), \(fmt($0.z)))" }.joined(separator: ", "))] (
                interpolation = "faceVarying"
            )
            texCoord2f[] primvars:st = [\(mesh.st.map { "(\(fmt($0.x)), \(fmt($0.y)))" }.joined(separator: ", "))] (
                interpolation = "faceVarying"
            )
            uniform token subdivisionScheme = "none"
            rel material:binding = </\(prim)/Materials/DieMaterial>
        }

        def Scope "Materials"
        {
            def Material "DieMaterial"
            {
                token outputs:surface.connect = </\(prim)/Materials/DieMaterial/PBRShader.outputs:surface>

                def Shader "PBRShader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </\(prim)/Materials/DieMaterial/DiffuseTexture.outputs:rgb>
                    float inputs:metallic = \(spec.metallic ? "0.85" : "0")
                    float inputs:roughness = \(spec.metallic ? "0.3" : "0.38")
                    token outputs:surface
                }

                def Shader "STReader"
                {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    token inputs:varname = "st"
                    float2 outputs:result
                }

                def Shader "DiffuseTexture"
                {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @\(spec.name)_diffuse.png@
                    float2 inputs:st.connect = </\(prim)/Materials/DieMaterial/STReader.outputs:result>
                    token inputs:wrapS = "repeat"
                    token inputs:wrapT = "repeat"
                    float3 outputs:rgb
                }
            }
        }
    }

    """
    s = s.replacingOccurrences(of: "\n    ", with: "\n")
    try s.write(to: outDir.appendingPathComponent("\(spec.name).usda"),
                atomically: true, encoding: .utf8)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2 else {
    print("Usage: swift GenerateDiceModels.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// d4: corner numbers are vertex values; roll = top vertex = opposite of the
// face resting on the felt. Faces exclude vertices 3,2,1,0 → values 4,3,2,1.
let (tetraVerts, tetraFaces) = tetrahedron()
let d4Tiles: [TileArt] = tetraFaces.map { face in
    .d4Corners(face.map { $0 + 1 })
}
_ = tetraVerts

let specs: [DieSpec] = [
    DieSpec(name: "d4", baseColor: 0xFFD93D, scale: 0.78, metallic: false,
            mesh: tetrahedron(), tiles: d4Tiles, materialImageName: "mat_wood_light"),
    DieSpec(name: "d6", baseColor: 0xFFFFFF, scale: 1, metallic: false,
            mesh: cube(half: 0.4), tiles: (0..<6).map { .pips([1, 2, 6, 5, 3, 4][$0]) },
            materialImageName: "mat_marble_white"),
    DieSpec(name: "d8", baseColor: 0xA78BFA, scale: 0.68, metallic: false,
            mesh: octahedron(), tiles: (1...8).map { .number("\($0)") },
            materialImageName: "mat_marble_green"),
    DieSpec(name: "d10", baseColor: 0xFB7185, scale: 0.66, metallic: false,
            mesh: trapezohedron(), tiles: (1...10).map { .number("\($0)") },
            materialImageName: "mat_copper"),
    DieSpec(name: "d12", baseColor: 0x34D399, scale: 0.66, metallic: false,
            mesh: dodecahedron(), tiles: (1...12).map { .number("\($0)") },
            materialImageName: "mat_marble_green"),
    DieSpec(name: "d20", baseColor: 0x4ECDC4, scale: 0.72, metallic: false,
            mesh: icosahedron(), tiles: (1...20).map { .number("\($0)") },
            materialImageName: "mat_steel"),
    DieSpec(name: "d100", baseColor: 0xF97316, scale: 0.66, metallic: false,
            mesh: trapezohedron(), tiles: (0...9).map { .number(String(format: "%02d", $0 * 10)) },
            materialImageName: "mat_copper")
]

for spec in specs {
    try generate(spec: spec, outDir: outDir)
    print("generated \(spec.name).usda + \(spec.name)_diffuse.png")
}
try generateCoin(outDir: outDir)
print("generated coin.usda + coin_diffuse.png")
