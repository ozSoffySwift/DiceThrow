import SwiftUI
import SceneKit
import simd

// MARK: - Wood box background

/// Insets (in the source photo's own point space) marking where the
/// photographed box's wooden rim ends and its canvas interior begins.
/// Drives the 9-slice cap below, and is mirrored in world units by
/// `DiceTable`'s play-area bounds so the invisible physics walls line up
/// with the printed rim's inner edge.
enum WoodBoxMetrics {
    static let capInsets = EdgeInsets(top: 54, leading: 57, bottom: 54, trailing: 52)
}

/// The entire background — border and interior alike — is one real
/// photographed open wooden box (Assets.xcassets/WoodBoxTexture). A resizable
/// 9-slice keeps the rim correctly proportioned on any screen size while the
/// interior stretches as a single continuous image — no tiling, no
/// synthetic gradients standing in for real wood.
struct WoodBorderView: View {
    var body: some View {
        Image("WoodBoxTexture")
            .resizable(capInsets: WoodBoxMetrics.capInsets, resizingMode: .stretch)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// SCNView wrapper carrying the felt-tap / die-tap / long-press-to-aim-and-throw gestures.
struct DiceTableView: UIViewRepresentable {
    let table: DiceTable
    var onTapFelt: (simd_float3) -> Void
    var onTapDie: (UUID) -> Void
    var onRemoveDie: (UUID) -> Void
    var onDirectionalThrow: (simd_float3) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = table.scene
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true   // keeps the physics simulation stepping
        view.rendersContinuously = true

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = 0.35
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(press)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: DiceTableView
        weak var view: SCNView?

        private var heldDieID: UUID?
        private var pressStartWorld: simd_float3?
        private var lastDragWorld: simd_float3?
        private var heldHeight: Float = 1.1
        private var isInRemoveZone = false

        init(parent: DiceTableView) {
            self.parent = parent
        }

        private func hitDieID(at point: CGPoint) -> UUID? {
            guard let view else { return nil }
            for hit in view.hitTest(point, options: nil) {
                if let name = hit.node.name, name.hasPrefix("die:"),
                   let id = UUID(uuidString: String(name.dropFirst(4))) {
                    return id
                }
            }
            return nil
        }

        /// World XZ under a screen point. The camera looks straight down
        /// (orthographic, no tilt), so XZ is the same regardless of which
        /// object's surface the hit-test actually lands on.
        private func worldPoint(at screenPoint: CGPoint) -> simd_float3? {
            guard let view, let hit = view.hitTest(screenPoint, options: nil).first else { return nil }
            let w = hit.worldCoordinates
            return simd_float3(Float(w.x), Float(w.y), Float(w.z))
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            if let id = hitDieID(at: point) {
                parent.onTapDie(id)
                return
            }
            if let hit = view.hitTest(point, options: nil).first {
                let w = hit.worldCoordinates
                parent.onTapFelt(simd_float3(Float(w.x), Float(w.y), Float(w.z)))
            }
        }

        /// Long-press a die to pick it up (it grows, physics freezes), drag to
        /// aim, then release to throw every die toward that direction. Drag
        /// the held die out past the box edge and release there to remove it
        /// instead — the "swipe it off-screen" alternative to throwing.
        @objc func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                let point = gesture.location(in: view)
                guard let id = hitDieID(at: point),
                      let node = parent.table.dieNode(id),
                      let start = worldPoint(at: point) else { return }
                heldDieID = id
                pressStartWorld = start
                lastDragWorld = start
                isInRemoveZone = false

                node.removeAllActions()
                node.physicsBody?.velocity = SCNVector3Zero
                node.physicsBody?.angularVelocity = SCNVector4(0, 0, 0, 0)
                node.physicsBody?.isAffectedByGravity = false
                node.opacity = 1.0

                let grow = SCNAction.group([
                    .scale(to: 1.5, duration: 0.18),
                    .move(to: SCNVector3(start.x, heldHeight, start.z), duration: 0.18)
                ])
                grow.timingMode = .easeOut
                node.runAction(grow, forKey: "hold")
                Haptics.impact(.medium)

            case .changed:
                guard let id = heldDieID, let node = parent.table.dieNode(id),
                      let start = pressStartWorld,
                      let current = worldPoint(at: gesture.location(in: view)) else { return }
                lastDragWorld = current

                node.position = SCNVector3(current.x, heldHeight, current.z)

                let dx = current.x - start.x
                let dz = current.z - start.z
                if (dx * dx + dz * dz) > 0.03 {
                    node.eulerAngles.y = atan2(dx, dz)
                }

                let outside = DiceTable.isOutsidePlayArea(current)
                if outside != isInRemoveZone {
                    isInRemoveZone = outside
                    Haptics.impact(outside ? .rigid : .light)
                }
                node.opacity = isInRemoveZone ? 0.4 : 1.0

            case .ended:
                guard let id = heldDieID, let node = parent.table.dieNode(id) else {
                    heldDieID = nil; pressStartWorld = nil; lastDragWorld = nil
                    return
                }
                node.removeAction(forKey: "hold")

                if isInRemoveZone {
                    node.opacity = 1.0
                    parent.onRemoveDie(id)
                    Haptics.impact(.rigid)
                } else {
                    node.opacity = 1.0
                    let start = pressStartWorld ?? SCNVector3ToFloat3(node.position)
                    let end = lastDragWorld ?? start
                    let drag = simd_float3(end.x - start.x, 0, end.z - start.z)
                    let direction = simd_length(drag) > 0.15 ? drag : simd_float3(
                        Float.random(in: -1...1), 0, Float.random(in: -1...1)
                    )
                    parent.onDirectionalThrow(direction)
                    Haptics.impact(.medium)
                }
                heldDieID = nil
                pressStartWorld = nil
                lastDragWorld = nil

            case .cancelled, .failed:
                if let id = heldDieID, let node = parent.table.dieNode(id) {
                    node.removeAction(forKey: "hold")
                    node.opacity = 1.0
                    node.physicsBody?.isAffectedByGravity = true
                    node.runAction(.scale(to: 1.0, duration: 0.15))
                }
                heldDieID = nil
                pressStartWorld = nil
                lastDragWorld = nil

            default:
                break
            }
        }
    }
}

private func SCNVector3ToFloat3(_ v: SCNVector3) -> simd_float3 {
    simd_float3(Float(v.x), Float(v.y), Float(v.z))
}

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard UserDefaults.standard.object(forKey: "hapticsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
