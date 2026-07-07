#!/usr/bin/swift
//
//  GenerateBoxModel.swift
//  Dice Throw asset pipeline
//
//  Generates a single USD model file (box.usda) for the open wooden play
//  box: a floor quad plus four inward-facing wall quads, textured with the
//  real photographed wood-box image already used for the 2D background
//  (DiceThrow/Assets.xcassets/WoodBoxTexture.imageset/wood-box-texture.png).
//  Floor UVs sample the photo's clean interior crop; wall UVs sample its
//  rim strips, so the model reads as one continuous piece of real wood,
//  matching the game's DiceTable play-area proportions (halfX/minZ/maxZ).
//
//  This file is a standalone asset — open in Reality Composer Pro — and is
//  NOT wired into the live game scene, which still renders the tuned 2D
//  wood-photo background (WoodBorderView).
//
//  Usage: swift Tools/GenerateBoxModel.swift DiceThrow/BoxModel <path-to-wood-photo>
//

import Foundation
import simd

struct GeneratedMesh {
    var counts: [Int] = []
    var indices: [Int] = []
    var points: [simd_float3] = []
    var normals: [simd_float3] = []
    var st: [simd_float2] = []
}

func fmt(_ v: Float) -> String { String(format: "%.5g", v) }

/// Appends a quad, auto-flipping winding order so its normal matches `desiredNormal`.
func addQuad(_ mesh: inout GeneratedMesh, _ p0: simd_float3, _ p1: simd_float3,
             _ p2: simd_float3, _ p3: simd_float3, desiredNormal: simd_float3,
             uv0: simd_float2, uv1: simd_float2, uv2: simd_float2, uv3: simd_float2) {
    var pts = [p0, p1, p2, p3]
    var uvs = [uv0, uv1, uv2, uv3]
    let n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
    if simd_dot(n, desiredNormal) < 0 {
        pts.reverse()
        uvs.reverse()
    }
    let base = mesh.points.count
    mesh.points += pts
    mesh.counts.append(4)
    for i in 0..<4 {
        mesh.indices.append(base + i)
        mesh.normals.append(desiredNormal)
        mesh.st.append(uvs[i])
    }
}

// MARK: - Box geometry (matches DiceThrow/DiceTable.swift play-area constants)

let halfX: Float = 2.3
let minZ: Float = -4.4
let maxZ: Float = 5.0
let wallHeight: Float = 0.9

let a = simd_float3(-halfX, 0, minZ)   // floor corners
let b = simd_float3(halfX, 0, minZ)
let c = simd_float3(halfX, 0, maxZ)
let d = simd_float3(-halfX, 0, maxZ)
let a2 = simd_float3(-halfX, wallHeight, minZ)  // wall-top corners
let b2 = simd_float3(halfX, wallHeight, minZ)
let c2 = simd_float3(halfX, wallHeight, maxZ)
let d2 = simd_float3(-halfX, wallHeight, maxZ)

// MARK: - UV crops from the real wood photo (measured rim thickness: see
// DiceThrow/DiceTableView.swift WoodBoxMetrics — top 78 / left 57 / bottom 78
// / right 52 out of a 579x1342 source image).
let imgW: Float = 579
let imgH: Float = 1342
let capTop: Float = 78, capLeft: Float = 57, capBottom: Float = 78, capRight: Float = 52

let interiorU0 = capLeft / imgW
let interiorU1 = (imgW - capRight) / imgW
let interiorV0 = capBottom / imgH   // v is bottom-up; bottom cap trims low-v
let interiorV1 = (imgH - capTop) / imgH

let leftRimU0: Float = 0, leftRimU1 = capLeft / imgW
let rightRimU0 = (imgW - capRight) / imgW, rightRimU1: Float = 1
let topRimV0 = (imgH - capTop) / imgH, topRimV1: Float = 1
let bottomRimV0: Float = 0, bottomRimV1 = capBottom / imgH

var mesh = GeneratedMesh()

// Floor (+Y), UVs sample the photo's clean interior crop.
addQuad(&mesh, a, b, c, d, desiredNormal: simd_float3(0, 1, 0),
        uv0: .init(interiorU0, interiorV0), uv1: .init(interiorU1, interiorV0),
        uv2: .init(interiorU1, interiorV1), uv3: .init(interiorU0, interiorV1))

// Wall at -Z (near/bottom edge in-game), inward normal +Z, top rim strip.
addQuad(&mesh, a, b, b2, a2, desiredNormal: simd_float3(0, 0, 1),
        uv0: .init(interiorU0, topRimV0), uv1: .init(interiorU1, topRimV0),
        uv2: .init(interiorU1, topRimV1), uv3: .init(interiorU0, topRimV1))

// Wall at +Z (far/top edge in-game), inward normal -Z, bottom rim strip.
addQuad(&mesh, d, c, c2, d2, desiredNormal: simd_float3(0, 0, -1),
        uv0: .init(interiorU0, bottomRimV0), uv1: .init(interiorU1, bottomRimV0),
        uv2: .init(interiorU1, bottomRimV1), uv3: .init(interiorU0, bottomRimV1))

// Wall at -X (left), inward normal +X, left rim strip.
addQuad(&mesh, a, d, d2, a2, desiredNormal: simd_float3(1, 0, 0),
        uv0: .init(leftRimU0, interiorV0), uv1: .init(leftRimU0, interiorV1),
        uv2: .init(leftRimU1, interiorV1), uv3: .init(leftRimU1, interiorV0))

// Wall at +X (right), inward normal -X, right rim strip.
addQuad(&mesh, b, c, c2, b2, desiredNormal: simd_float3(-1, 0, 0),
        uv0: .init(rightRimU1, interiorV0), uv1: .init(rightRimU1, interiorV1),
        uv2: .init(rightRimU0, interiorV1), uv3: .init(rightRimU0, interiorV0))

// MARK: - USDA + texture output

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift GenerateBoxModel.swift <output-dir> <path-to-wood-photo>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let sourcePhoto = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let textureName = "box_diffuse.png"
let destPhoto = outDir.appendingPathComponent(textureName)
if FileManager.default.fileExists(atPath: destPhoto.path) {
    try FileManager.default.removeItem(at: destPhoto)
}
try FileManager.default.copyItem(at: sourcePhoto, to: destPhoto)

let prim = "Box"
var s = """
#usda 1.0
(
    defaultPrim = "\(prim)"
    metersPerUnit = 1
    upAxis = "Y"
    doc = "Dice Throw – open wooden play box. Generated by Tools/GenerateBoxModel.swift from the real photographed wood-box texture; open in Reality Composer Pro. Reference asset only — the live game still renders the 2D WoodBorderView background."
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
        rel material:binding = </\(prim)/Materials/WoodMaterial>
    }

    def Scope "Materials"
    {
        def Material "WoodMaterial"
        {
            token outputs:surface.connect = </\(prim)/Materials/WoodMaterial/PBRShader.outputs:surface>

            def Shader "PBRShader"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor.connect = </\(prim)/Materials/WoodMaterial/DiffuseTexture.outputs:rgb>
                float inputs:metallic = 0
                float inputs:roughness = 0.85
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
                asset inputs:file = @\(textureName)@
                float2 inputs:st.connect = </\(prim)/Materials/WoodMaterial/STReader.outputs:result>
                token inputs:wrapS = "clamp"
                token inputs:wrapT = "clamp"
                float3 outputs:rgb
            }
        }
    }
}

"""
try s.write(to: outDir.appendingPathComponent("box.usda"), atomically: true, encoding: .utf8)
print("generated box.usda + \(textureName) in \(outDir.path)")
