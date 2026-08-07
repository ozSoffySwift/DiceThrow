import Foundation
import SceneKit
import Metal

// physicsBody.velocity is dead in a headless SCNRenderer, but the presentation
// transform is live — so derive true linear/angular speed from frame-to-frame
// deltas and evaluate the real settle policies against them.
//
// Units: presentation advances by physicsWorld.speed per unit of `atTime`, so a
// derived speed is per REAL second. The app's thresholds are per SIMULATED
// second, hence the x1.35 conversion below.

let halfX: Float = 2.3, minZ: Float = -4.4, maxZ: Float = 5.0
let midZ = (minZ + maxZ) / 2
let SPEED: Float = 1.35

let d6Normals: [simd_float3] = [.init(0,0,1), .init(1,0,0), .init(0,0,-1),
                                .init(-1,0,0), .init(0,1,0), .init(0,-1,0)]
let d6Values = [1, 2, 6, 5, 3, 4]

func makeScene(dieGeo: SCNGeometry, count: Int, seed: UInt64) -> (SCNScene, [SCNNode]) {
    let scene = SCNScene()
    scene.physicsWorld.speed = CGFloat(SPEED)
    let tn = SCNNode(geometry: SCNBox(width: 16, height: 0.5, length: 20, chamferRadius: 0))
    tn.position = SCNVector3(0, -0.25, 0.3)
    tn.physicsBody = { let b = SCNPhysicsBody(type: .static, shape: nil)
        b.friction = 0.9; b.restitution = 0.38; b.categoryBitMask = 2; return b }()
    scene.rootNode.addChildNode(tn)
    func addRail(width: CGFloat, length: CGFloat, x: Float, z: Float) {
        for (h, y, rest) in [(CGFloat(0.9), Float(0.45), 0.5), (CGFloat(6), Float(3.2), 0.45)] {
            let n = SCNNode(geometry: SCNBox(width: width, height: h, length: length, chamferRadius: 0))
            n.position = SCNVector3(x, y, z)
            n.physicsBody = { let b = SCNPhysicsBody(type: .static, shape: nil)
                b.restitution = CGFloat(rest); b.categoryBitMask = 4; return b }()
            scene.rootNode.addChildNode(n)
        }
    }
    let rt: CGFloat = 0.5, off = Float(rt)/2
    addRail(width: rt, length: CGFloat(maxZ-minZ) + rt*2, x: -(halfX+off), z: midZ)
    addRail(width: rt, length: CGFloat(maxZ-minZ) + rt*2, x: halfX+off, z: midZ)
    addRail(width: CGFloat(halfX)*2, length: rt, x: 0, z: minZ-off)
    addRail(width: CGFloat(halfX)*2, length: rt, x: 0, z: maxZ+off)
    let ceil = SCNNode(geometry: SCNBox(width: 16, height: 0.5, length: 20, chamferRadius: 0))
    ceil.position = SCNVector3(0, 6.8, 0.3)
    ceil.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
    ceil.physicsBody?.restitution = 0.1; ceil.physicsBody?.categoryBitMask = 2
    scene.rootNode.addChildNode(ceil)
    let cam = SCNNode(); cam.camera = SCNCamera()
    cam.camera!.usesOrthographicProjection = true; cam.camera!.orthographicScale = 5.85
    cam.position = SCNVector3(0, 14, midZ); cam.eulerAngles = SCNVector3(-Float.pi/2, 0, 0)
    scene.rootNode.addChildNode(cam)

    var dice: [SCNNode] = []
    var s = seed
    func rnd(_ lo: Float, _ hi: Float) -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return lo + (hi - lo) * Float(Double(s >> 33) / Double(UInt64(1) << 31))
    }
    for i in 0..<count {
        let n = SCNNode(geometry: dieGeo)
        n.position = SCNVector3(rnd(-1.5, 1.5), 1.2 + Float(i)*0.6, midZ + rnd(-1, 1))
        n.eulerAngles = SCNVector3(rnd(0,6.28), rnd(0,6.28), rnd(0,6.28))
        let b = SCNPhysicsBody(type: .dynamic,
            shape: SCNPhysicsShape(geometry: dieGeo, options: [.type: SCNPhysicsShape.ShapeType.convexHull]))
        b.mass = 0.12; b.friction = 0.55; b.rollingFriction = 0.32
        b.restitution = 0.42; b.angularDamping = 0.28; b.damping = 0.12; b.categoryBitMask = 1
        n.physicsBody = b
        scene.rootNode.addChildNode(n)
        b.velocity = SCNVector3(rnd(-2.2,2.2), rnd(5.8,7.2), rnd(-2.2,2.2))
        b.angularVelocity = SCNVector4(rnd(-1.2,1.2), rnd(-1.2,1.2), rnd(-1.2,1.2), rnd(10,18))
        dice.append(n)
    }
    return (scene, dice)
}

func faceValue(_ m: simd_float4x4) -> Int {
    let rot = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1),
                            simd_make_float3(m.columns.2))
    var best = 0; var bd = -Float.infinity
    for (i, n) in d6Normals.enumerated() {
        let d = simd_dot(simd_normalize(rot * n), simd_float3(0,1,0))
        if d > bd { bd = d; best = i }
    }
    return d6Values[best]
}

guard let loaded = try? SCNScene(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: nil) else { exit(1) }
var dieGeo: SCNGeometry?
loaded.rootNode.enumerateChildNodes { n, stop in
    if dieGeo == nil, let g = n.geometry { dieGeo = g; stop.pointee = true } }

let device = MTLCreateSystemDefaultDevice()!
let TRIALS = 100, dt = 1.0/60.0

// derived (per real second) thresholds
let OLD_V: Float = sqrt(0.09) * SPEED      // 0.30 sim -> 0.405 real
let OLD_W: Float = 0.9 * SPEED             // 1.215 real
let NEW_V: Float = sqrt(0.06)              // app: sqrt(0.06)/SPEED sim -> 0.245 real
let NEW_W: Float = 0.5                     // app: 0.5/SPEED sim -> 0.5 real


struct Policy { let name: String; let v: Float; let w: Float; let k: Int; let timeout: Double }
let policies: [Policy] = [
    Policy(name: "shipped v1.1 (the bug)",     v: OLD_V, w: OLD_W, k: 0, timeout: 2.6),
    Policy(name: "FINAL v.08 w.18 K=4 to=5.0", v: 0.08, w: 0.18, k: 4, timeout: 5.0),
]
var wrong = [Int](repeating: 0, count: policies.count)
var times = [[Double]](repeating: [], count: policies.count)
var viaTimeout = [Int](repeating: 0, count: policies.count)

for trial in 0..<TRIALS {
    let (scene, dice) = makeScene(dieGeo: dieGeo!, count: 2, seed: UInt64(trial &* 7919 &+ 13))
    let r = SCNRenderer(device: device, options: nil); r.scene = scene
    r.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
    var t = 0.0, nextPoll = 0.05
    var prevM = dice.map { $0.presentation.simdWorldTransform }
    var prevT = 0.0
    var samples: [(Double, [Int], Float, Float)] = []
    while t < 6.0 {
        _ = r.snapshot(atTime: t, with: CGSize(width: 8, height: 8), antialiasingMode: .none)
        if t >= nextPoll {
            nextPoll += 0.05
            let cur = dice.map { $0.presentation.simdWorldTransform }
            let h = Float(max(t - prevT, 1e-6))
            var maxV: Float = 0, maxW: Float = 0
            for i in 0..<cur.count {
                let p0 = simd_make_float3(prevM[i].columns.3), p1 = simd_make_float3(cur[i].columns.3)
                maxV = max(maxV, simd_length(p1 - p0) / h)
                let q0 = simd_quatf(simd_float3x3(simd_make_float3(prevM[i].columns.0),
                    simd_make_float3(prevM[i].columns.1), simd_make_float3(prevM[i].columns.2)))
                let q1 = simd_quatf(simd_float3x3(simd_make_float3(cur[i].columns.0),
                    simd_make_float3(cur[i].columns.1), simd_make_float3(cur[i].columns.2)))
                maxW = max(maxW, 2 * acos(min(1, abs((q1 * q0.inverse).real))) / h)
            }
            if t > 0.35 { samples.append((t, cur.map { faceValue($0) }, maxV, maxW)) }
            prevM = cur; prevT = t
        }
        t += dt
    }
    guard let finalVals = samples.last?.1 else { continue }
    for (pi, pol) in policies.enumerated() {
        var run = 0; var prev: [Int]? = nil; var done = false
        for (st, sv, v, w) in samples where !done {
            let slow = v < pol.v && w < pol.w
            if pol.k == 0 {
                if slow || st > pol.timeout {
                    done = true; times[pi].append(st)
                    if st > pol.timeout { viaTimeout[pi] += 1 }
                    if sv != finalVals { wrong[pi] += 1 }
                }
            } else {
                if slow, let p = prev, p == sv { run += 1 } else { run = 0 }
                prev = sv
                if run >= pol.k || st > pol.timeout {
                    done = true; times[pi].append(st)
                    if run < pol.k { viaTimeout[pi] += 1 }
                    if sv != finalVals { wrong[pi] += 1 }
                }
            }
        }
    }
}
func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0,+)/Double(a.count) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
print(pad("policy", 34) + pad("wrong", 12) + pad("avg time", 11) + "via timeout")
for (i, p) in policies.enumerated() {
    let t = String(format: "%.2fs", avg(times[i]))
    print(pad(p.name, 34) + pad("\(wrong[i])/\(TRIALS)", 12) + pad(t, 11) + "\(viaTimeout[i])")
}
