import SceneKit
import UIKit
import simd

/// Owns the SceneKit scene: felt table, wood rails, lighting, the dice bodies,
/// throw impulses, settle detection, and reading rolled values from the
/// physical resting orientation of each die.
final class DiceTable: NSObject, ObservableObject, SCNPhysicsContactDelegate {

    // Play area in world units (portrait framing, camera looks down the -y axis).
    static let halfX: Float = 2.3
    static let minZ: Float = -4.4
    static let maxZ: Float = 5.0

    /// True once a point is dragged far enough past the play-area edge to
    /// count as "pulled out of the box" — used by the long-press remove gesture.
    static func isOutsidePlayArea(_ point: simd_float3, margin: Float = 0.25) -> Bool {
        abs(point.x) > halfX + margin || point.z < minZ - margin || point.z > maxZ + margin
    }

    let scene = SCNScene()

    @Published var rolling = false

    /// The outcome of one throw, handed to `onSettled`.
    struct Outcome {
        let rolls: [DieRoll]
        let total: Int
        /// Wall-clock seconds from throw start to the dice being declared settled.
        let settleDuration: TimeInterval
        /// True when the safety timeout fired rather than the dice actually resting.
        let timedOut: Bool
    }

    /// Called on the main queue when all dice come to rest.
    var onSettled: ((Outcome) -> Void)?
    var soundEnabled: () -> Bool = { true }

    private var diceNodes: [UUID: SCNNode] = [:]
    private var dicePool: [PooledDie] = []
    private var settleTimer: Timer?
    private var throwStartedAt: Date?
    private var displayLink: CADisplayLink?

    // Per-die sound budget for the current throw: one sound on the first
    // surface contact, then up to 3 more once that die has slowed down
    // enough to be settling — instead of a sound on every single bounce.
    private var firstHitPlayed: Set<UUID> = []
    private var settleSoundCount: [UUID: Int] = [:]

    override init() {
        super.init()
        buildScene()
    }

    // MARK: - Scene construction

    private func buildScene() {
        scene.background.contents = UIColor.clear
        scene.physicsWorld.contactDelegate = self
        // Run the simulation slightly fast-forward. Real dice at this scale take a
        // beat longer to settle than feels good on a phone, and scaling time is
        // cheaper than re-tuning every mass, impulse and friction value to match.
        scene.physicsWorld.speed = 1.35

        // Invisible floor — the real wood box photo (WoodBorderView, behind the
        // SceneKit layer) is the visible surface — but this one still writes
        // depth and receives shadows, so dice cast a real contact shadow onto
        // it (colorBufferWriteMask empty = no color output, so it stays
        // invisible everywhere except where a shadow darkens it).
        let table = SCNBox(width: 16, height: 0.5, length: 20, chamferRadius: 0)
        let floorMaterial = SCNMaterial()
        floorMaterial.diffuse.contents = UIColor.black
        floorMaterial.lightingModel = .physicallyBased
        floorMaterial.colorBufferWriteMask = []
        floorMaterial.writesToDepthBuffer = true
        floorMaterial.readsFromDepthBuffer = true
        table.materials = [floorMaterial]
        let tableNode = SCNNode(geometry: table)
        tableNode.name = "table"
        tableNode.castsShadow = false
        tableNode.position = SCNVector3(0, -0.25, 0.3)
        tableNode.physicsBody = {
            let body = SCNPhysicsBody(type: .static, shape: nil)
            body.friction = 0.9
            body.restitution = 0.38
            body.categoryBitMask = 2
            return body
        }()
        scene.rootNode.addChildNode(tableNode)

        // Invisible box walls at the play-area edge — dice bounce here, right at
        // the inner line of the printed border in WoodBorderView.
        let railThickness: CGFloat = 0.5
        let innerW = CGFloat(Self.halfX) * 2
        let innerL = CGFloat(Self.maxZ - Self.minZ)
        let midZ = (Self.maxZ + Self.minZ) / 2

        func addRail(width: CGFloat, length: CGFloat, x: Float, z: Float) {
            let rail = SCNBox(width: width, height: 0.9, length: length, chamferRadius: 0.05)
            let node = SCNNode(geometry: rail)
            node.name = "wall"
            node.opacity = 0
            node.position = SCNVector3(x, 0.45, z)
            node.castsShadow = false
            node.physicsBody = {
                let body = SCNPhysicsBody(type: .static, shape: nil)
                body.restitution = 0.5
                body.categoryBitMask = 4
                return body
            }()
            scene.rootNode.addChildNode(node)

            // Taller invisible extension so lively dice can't hop the rail.
            let wall = SCNBox(width: width, height: 6, length: length, chamferRadius: 0)
            let wallNode = SCNNode(geometry: wall)
            wallNode.name = "wall"
            wallNode.position = SCNVector3(x, 3.2, z)
            wallNode.opacity = 0
            wallNode.castsShadow = false
            wallNode.physicsBody = {
                let body = SCNPhysicsBody(type: .static, shape: nil)
                body.restitution = 0.45
                body.categoryBitMask = 4
                return body
            }()
            scene.rootNode.addChildNode(wallNode)
        }

        let railOffset = Float(railThickness) / 2
        addRail(width: railThickness, length: innerL + railThickness * 2,
                x: -(Self.halfX + railOffset), z: midZ)
        addRail(width: railThickness, length: innerL + railThickness * 2,
                x: Self.halfX + railOffset, z: midZ)
        addRail(width: innerW, length: railThickness, x: 0, z: Self.minZ - railOffset)
        addRail(width: innerW, length: railThickness, x: 0, z: Self.maxZ + railOffset)

        // Invisible ceiling keeps throws inside the camera frustum.
        let ceiling = SCNNode(geometry: SCNBox(width: 16, height: 0.5, length: 20, chamferRadius: 0))
        ceiling.position = SCNVector3(0, 6.8, 0.3)
        ceiling.opacity = 0
        ceiling.castsShadow = false
        ceiling.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        ceiling.physicsBody?.restitution = 0.1
        ceiling.physicsBody?.categoryBitMask = 2
        scene.rootNode.addChildNode(ceiling)

        // Camera: directly overhead, looking straight down — a true vertical
        // top-down view (no tilt) so the 3D dice match the flat photo backdrop.
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 5.85
        camera.zNear = 1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let midPlayZ = (Self.minZ + Self.maxZ) / 2
        cameraNode.position = SCNVector3(0, 14, midPlayZ)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        // Key light with shadows + soft ambient fill. The shadow is the only depth
        // cue in a straight-down orthographic view — without it a die at the top of
        // its arc looks identical to one lying flat — so it's tuned for legibility
        // in flight rather than for subtlety.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 950
        key.castsShadow = true
        // Shadow projection is left automatic on purpose. Fitting it by hand to the
        // play area recovers texel density in theory, but in this scene it silently
        // produced no shadow at all under the deferred pass — and a correct-on-paper
        // frustum is worth nothing against a shadow you can't see. A bigger map buys
        // most of the same sharpness with none of the risk.
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        // With the resolution recovered the blur can come down from 6, which was
        // wide enough to smear an airborne die into a barely-visible smudge.
        key.shadowRadius = 3
        key.shadowSampleCount = 16
        key.shadowColor = UIColor.black.withAlphaComponent(0.75)
        key.shadowMode = .deferred
        let keyNode = SCNNode()
        keyNode.light = key
        // ~21 degrees off vertical. Under a straight-down camera the tilt is what
        // turns height into a visible horizontal gap (~0.38 x height), so it is the
        // depth cue — flatten it toward vertical and a resting die's shadow hides
        // completely underneath it. Keep the angle; the fix for legibility is
        // resolution, darkness and blur above, not geometry.
        keyNode.eulerAngles = SCNVector3(-Float.pi / 2.6, -0.4, 0)
        scene.rootNode.addChildNode(keyNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 420
        ambient.color = UIColor(white: 0.9, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        startFrameLoop()
    }

    // Gravity is intentionally fixed straight down (SceneKit's default) —
    // no device-tilt gyro coupling. A common use case is holding the phone
    // in hand, which is naturally tilted, and gyro-driven gravity would keep
    // sliding every die toward whichever edge that tilt points to instead of
    // letting them land anywhere on the table.
    private func startFrameLoop() {
        let displayLink = CADisplayLink(target: self, selector: #selector(onFrame))
        displayLink.preferredFramesPerSecond = 60
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func onFrame() {
        updateSlideSound()
    }

    /// Continuous "sliding across the wood floor" sound. Runs every frame
    /// while dice are in motion; volume tracks the combined horizontal speed
    /// of every die that's currently grounded (as opposed to airborne mid-bounce),
    /// so it swells with a big scattering throw and fades as everything settles.
    private func updateSlideSound() {
        guard rolling, soundEnabled() else {
            SoundSynth.shared.updateSlide(intensity: 0)
            return
        }
        var energy: Float = 0
        for node in diceNodes.values {
            guard let body = node.physicsBody else { continue }
            let v = body.velocity
            let horizontalSpeed = (v.x * v.x + v.z * v.z).squareRoot()
            let isGrounded = node.presentation.position.y < 0.9 && abs(v.y) < 1.4
            if isGrounded && horizontalSpeed > 0.15 {
                energy += horizontalSpeed
            }
        }
        SoundSynth.shared.updateSlide(intensity: energy)
    }

    // MARK: - Pool management

    /// Adds/removes dice nodes to match the pool. New dice drop onto the table.
    func syncPool(_ pool: [PooledDie]) {
        dicePool = pool
        let ids = Set(pool.map(\.id))
        for (id, node) in diceNodes where !ids.contains(id) {
            node.runAction(.sequence([.scale(to: 0.01, duration: 0.18), .removeFromParentNode()]))
            diceNodes.removeValue(forKey: id)
        }
        for die in pool where diceNodes[die.id] == nil {
            let node = makeDieNode(die)
            node.position = SCNVector3(
                Float.random(in: -Self.halfX * 0.6...Self.halfX * 0.6),
                Float.random(in: 2.2...3.2),
                Float.random(in: Self.minZ * 0.5...Self.maxZ * 0.5)
            )
            node.eulerAngles = SCNVector3(Float.random(in: 0...(.pi)),
                                          Float.random(in: 0...(.pi)),
                                          Float.random(in: 0...(.pi)))
            scene.rootNode.addChildNode(node)
            diceNodes[die.id] = node
        }
    }

    func diePosition(_ id: UUID) -> simd_float3? {
        guard let node = diceNodes[id] else { return nil }
        return node.presentation.simdWorldPosition
    }

    func dieNode(_ id: UUID) -> SCNNode? { diceNodes[id] }

    private func makeDieNode(_ die: PooledDie) -> SCNNode {
        let mesh = DieMeshFactory.mesh(for: die.type)
        let node = SCNNode(geometry: mesh.geometry)
        node.name = "die:\(die.id.uuidString)"
        let shape = SCNPhysicsShape(geometry: mesh.geometry,
                                    options: [.type: SCNPhysicsShape.ShapeType.convexHull])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = 0.12
        body.friction = 0.55
        body.rollingFriction = 0.32
        body.restitution = 0.42
        body.angularDamping = 0.28
        body.damping = 0.12
        body.categoryBitMask = 1
        body.contactTestBitMask = 2 | 1 | 4
        node.physicsBody = body
        return node
    }

    // MARK: - Throwing

    /// Throw every die. With an origin the dice launch from that world point
    /// (felt tap / die tap); with nil they jump from where they rest (button, shake).
    ///
    /// If a throw is already in flight, this interrupts it instead of being
    /// ignored: the pending settle check is cancelled (so the interrupted
    /// throw never reports a result) and every die is relaunched immediately
    /// from wherever it currently is — no reset, no pick-up windup — then a
    /// fresh settle check starts for the new throw.
    func throwAll(from origin: simd_float3?) {
        guard !dicePool.isEmpty else { return }
        let wasRolling = rolling

        settleTimer?.invalidate()
        settleTimer = nil

        rolling = true
        throwStartedAt = Date()
        firstHitPlayed.removeAll()
        settleSoundCount.removeAll()
        if soundEnabled() { SoundSynth.shared.prepare() }

        for (index, die) in dicePool.enumerated() {
            guard let node = diceNodes[die.id] else { continue }
            node.removeAllActions()

            if wasRolling {
                // Interrupting an in-flight throw: redirect in place, right
                // from the die's current position and velocity — no windup.
                node.scale = SCNVector3(1, 1, 1)
                applyThrowVelocity(die: die, origin: origin, index: index, reposition: false)
                continue
            }

            // Fresh throw from rest: brief pick-up/gather windup, then release.
            let gatherY: Float = origin != nil ? 0.8 : 1.5
            let gatherX = origin?.x ?? Float(0)
            let gatherZ = origin?.z ?? Float(0)
            let gatherPos = SCNVector3(gatherX, gatherY, gatherZ)

            let gatherScale = SCNVector3(0.5, 0.5, 0.5)
            let currentPos = node.position
            let currentScale = node.scale

            // Compress to gather point (0.08 seconds)
            let gatherAction = SCNAction.sequence([
                .customAction(duration: 0.05) { n, elapsed in
                    let progress = Float(elapsed) / 0.08
                    let dx = gatherPos.x - currentPos.x
                    let dy = gatherPos.y - currentPos.y
                    let dz = gatherPos.z - currentPos.z
                    n.position = SCNVector3(
                        currentPos.x + dx * progress,
                        currentPos.y + dy * progress,
                        currentPos.z + dz * progress
                    )
                    let sx = gatherScale.x - currentScale.x
                    let sy = gatherScale.y - currentScale.y
                    let sz = gatherScale.z - currentScale.z
                    n.scale = SCNVector3(
                        currentScale.x + sx * progress,
                        currentScale.y + sy * progress,
                        currentScale.z + sz * progress
                    )
                },
                .run { [weak self] _ in
                    self?.applyThrowVelocity(die: die, origin: origin, index: index, reposition: true)
                }
            ])

            node.runAction(gatherAction)
        }

        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkSettled()
        }
    }

    /// Applies a fresh launch impulse. When `reposition` is true (a normal
    /// throw from rest) the die is first placed above the origin/gather
    /// point; when false (redirecting an already-moving die) it launches
    /// from wherever it currently is.
    private func applyThrowVelocity(die: PooledDie, origin: simd_float3?, index: Int, reposition: Bool) {
        guard let node = diceNodes[die.id], let body = node.physicsBody else { return }
        body.clearAllForces()

        if reposition {
            node.runAction(.scale(to: 1.0, duration: 0.1))
        }

        if let origin = origin {
            if reposition {
                // Tap throw: gather above point, fling toward felt
                node.position = SCNVector3(
                    min(max(origin.x, -Self.halfX + 0.5), Self.halfX - 0.5)
                        + Float.random(in: -0.25...0.25),
                    1.2 + Float(index) * 0.6,
                    min(max(origin.z, Self.minZ + 0.5), Self.maxZ - 0.5)
                        + Float.random(in: -0.25...0.25)
                )
                body.resetTransform()
            }
            // Direction depends on where you tapped: dice scatter away from
            // the tap point, through the box center, toward the far side —
            // like flicking them from wherever you touched.
            let centerZ = (Self.minZ + Self.maxZ) / 2
            let awayFromTap = simd_float3(origin.x, 0, origin.z) - simd_float3(0, 0, centerZ)
            let baseDir = simd_length(awayFromTap) > 0.1 ? -simd_normalize(awayFromTap) : simd_float3(0, 0, 1)
            let spreadAngle = Float.random(in: -0.7...0.7)
            let dir = simd_float3(
                baseDir.x * cos(spreadAngle) - baseDir.z * sin(spreadAngle),
                0,
                baseDir.x * sin(spreadAngle) + baseDir.z * cos(spreadAngle)
            )
            let speed = Float.random(in: 2.8...4.2)
            body.velocity = SCNVector3(dir.x * speed,
                                       Float.random(in: 3.5...4.8),
                                       dir.z * speed)
        } else {
            // Shake throw: explosive launch from current position
            body.velocity = SCNVector3(Float.random(in: -2.2...2.2),
                                       Float.random(in: 5.8...7.2),
                                       Float.random(in: -2.2...2.2))
        }

        body.angularVelocity = SCNVector4(Float.random(in: -1.2...1.2),
                                          Float.random(in: -1.2...1.2),
                                          Float.random(in: -1.2...1.2),
                                          Float.random(in: 10...18))
    }

    /// Throws every die toward `direction` (world-space XZ, need not be
    /// normalized) — used by the long-press-and-aim gesture. Launches each
    /// die from wherever it currently is with no repositioning or windup,
    /// since the gesture's own grow/hold animation already served as the
    /// wind-up. Interrupts an in-flight throw the same way `throwAll` does.
    func throwAllDirectional(_ direction: simd_float3) {
        guard !dicePool.isEmpty else { return }
        settleTimer?.invalidate()
        settleTimer = nil

        rolling = true
        throwStartedAt = Date()
        firstHitPlayed.removeAll()
        settleSoundCount.removeAll()
        if soundEnabled() { SoundSynth.shared.prepare() }

        let dir = simd_length(direction) > 0.01 ? simd_normalize(direction) : simd_float3(0, 0, 1)

        for die in dicePool {
            guard let node = diceNodes[die.id], let body = node.physicsBody else { continue }
            node.removeAllActions()
            node.scale = SCNVector3(1, 1, 1)
            body.isAffectedByGravity = true
            body.clearAllForces()

            let spreadAngle = Float.random(in: -0.5...0.5)
            let launchDir = simd_float3(
                dir.x * cos(spreadAngle) - dir.z * sin(spreadAngle),
                0,
                dir.x * sin(spreadAngle) + dir.z * cos(spreadAngle)
            )
            let speed = Float.random(in: 3.4...5.0)
            body.velocity = SCNVector3(launchDir.x * speed,
                                       Float.random(in: 4.4...5.8),
                                       launchDir.z * speed)
            body.angularVelocity = SCNVector4(Float.random(in: -1.2...1.2),
                                              Float.random(in: -1.2...1.2),
                                              Float.random(in: -1.2...1.2),
                                              Float.random(in: 10...18))
        }

        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkSettled()
        }
    }

    private func checkSettled() {
        guard let start = throwStartedAt else { return }
        let elapsed = -start.timeIntervalSinceNow
        // Just long enough that a die can't be declared settled while it's still
        // being launched. Anything beyond that is dead waiting: the dice have
        // stopped, and we'd only be holding the number back.
        guard elapsed > 0.35 else { return }

        let allResting = diceNodes.values.allSatisfy { node in
            guard let body = node.physicsBody else { return true }
            let v = body.velocity
            let speedSq = v.x * v.x + v.y * v.y + v.z * v.z
            return speedSq < 0.09 && abs(body.angularVelocity.w) < 0.9
        }
        // Fallback for a die that creeps or wobbles against a rail without ever
        // dipping under the rest thresholds — its face has long since stopped changing.
        if allResting || elapsed > 2.6 {
            finishThrow(settleDuration: elapsed, timedOut: !allResting)
        }
    }

    private func finishThrow(settleDuration: TimeInterval, timedOut: Bool) {
        settleTimer?.invalidate()
        settleTimer = nil
        throwStartedAt = nil

        var rolls: [DieRoll] = []
        for die in dicePool {
            rolls.append(DieRoll(type: die.type, value: readValue(die)))
        }
        let total = rolls.reduce(0) { $0 + $1.value }

        rolling = false
        onSettled?(Outcome(rolls: rolls, total: total,
                           settleDuration: settleDuration, timedOut: timedOut))
    }

    /// Reads a die's value from whichever face normal points most upward
    /// (downward for the d4) in its physical resting orientation.
    private func readValue(_ die: PooledDie) -> Int {
        let mesh = DieMeshFactory.mesh(for: die.type)
        guard let node = diceNodes[die.id] else { return 1 }

        let t = node.presentation.simdWorldTransform
        let rotation = simd_float3x3(
            simd_make_float3(t.columns.0),
            simd_make_float3(t.columns.1),
            simd_make_float3(t.columns.2)
        )
        let up = simd_float3(0, 1, 0)
        var bestIndex = 0
        var bestDot = -Float.infinity
        for (i, normal) in mesh.faceNormals.enumerated() {
            var d = simd_dot(simd_normalize(rotation * normal), up)
            if mesh.readsBottomFace { d = -d }
            if d > bestDot { bestDot = d; bestIndex = i }
        }
        return mesh.faceValues[bestIndex]
    }

    // MARK: - Contact sounds

    /// Each die gets a fixed sound budget for the whole throw instead of a
    /// sound on every bounce: one on its very first surface contact, then up
    /// to 3 more once it's slowed down enough to be settling — like the last
    /// few wobbles before a real die stops. Dice-on-dice bumps stay silent.
    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        guard rolling, soundEnabled() else { return }

        let nodeAName = contact.nodeA.name ?? ""
        let nodeBName = contact.nodeB.name ?? ""
        let isWall = nodeAName == "wall" || nodeBName == "wall"
        let isFloor = nodeAName == "table" || nodeBName == "table"
        guard isWall || isFloor else { return }

        guard let dieNodeName = nodeAName.hasPrefix("die:") ? nodeAName
                : (nodeBName.hasPrefix("die:") ? nodeBName : nil),
              let dieID = UUID(uuidString: String(dieNodeName.dropFirst(4))) else { return }

        // `contact.collisionImpulse` is unreliable for static-vs-dynamic
        // contacts on this physics setup (it reads back as 0), so derive an
        // impact strength from the body velocities at the moment of contact.
        let vA = contact.nodeA.physicsBody?.velocity ?? SCNVector3Zero
        let vB = contact.nodeB.physicsBody?.velocity ?? SCNVector3Zero
        let speedA = simd_length(simd_float3(vA.x, vA.y, vA.z))
        let speedB = simd_length(simd_float3(vB.x, vB.y, vB.z))
        let impactSpeed = max(speedA, speedB)
        guard impactSpeed > 0.2 else { return }

        var shouldPlay = false
        if !firstHitPlayed.contains(dieID) {
            firstHitPlayed.insert(dieID)
            shouldPlay = true
        } else if impactSpeed < 1.4, (settleSoundCount[dieID] ?? 0) < 3 {
            settleSoundCount[dieID, default: 0] += 1
            shouldPlay = true
        }
        guard shouldPlay else { return }

        let volume = min(1, impactSpeed / 7.0)
        let isCoin = dicePool.contains { $0.id == dieID && $0.type == .coin }

        DispatchQueue.main.async {
            if isCoin {
                SoundSynth.shared.coinRing()
            } else if isWall {
                SoundSynth.shared.wallKnock(volume: volume)
            } else {
                SoundSynth.shared.floorTap(volume: volume)
            }
        }
    }

    deinit {
        stopFrameLoop()
    }

    private func stopFrameLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - Table textures

private enum TableTextures {
    /// Real photographed wood-grain crop (see Assets.xcassets/WoodBoxTexture),
    /// tiled across the floor and rail walls of the 3D box.
    static let wood: UIImage = UIImage(named: "WoodBoxTexture") ?? UIImage()
}
