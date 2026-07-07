import SwiftUI
import SwiftData

// MARK: - Die types

enum DieType: String, Codable, CaseIterable, Identifiable {
    case coin, d4, d6, d8, d10, d20

    var id: String { rawValue }

    var sides: Int {
        switch self {
        case .coin: 2
        case .d4: 4
        case .d6: 6
        case .d8: 8
        case .d10: 10
        case .d20: 20
        }
    }

    var label: String { self == .coin ? "Coin" : rawValue }

    /// Lowest/highest/average face value — the coin reads 0/1 rather than
    /// 1/sides, so these can't be derived from `sides` alone.
    var minFaceValue: Int { self == .coin ? 0 : 1 }
    var maxFaceValue: Int { self == .coin ? 1 : sides }
    var meanFaceValue: Double { Double(minFaceValue + maxFaceValue) / 2 }

    var uiAccent: UIColor {
        switch self {
        case .coin: UIColor(hex: 0xC7C9CC)
        case .d4:   UIColor(hex: 0xFFD93D)
        case .d6:   UIColor(hex: 0xFFFFFF)
        case .d8:   UIColor(hex: 0xA78BFA)
        case .d10:  UIColor(hex: 0xFB7185)
        case .d20:  UIColor(hex: 0x4ECDC4)
        }
    }

    var accent: Color { Color(uiColor: uiAccent) }

    /// Photographed material tile (bundled as `<name>.png`) each die is
    /// rendered with — mirrors Tools/GenerateDiceModels.swift's assignment
    /// so the dock icons, procedural fallback, and real USD models all agree.
    var materialImageName: String {
        switch self {
        case .coin: "mat_gold"
        case .d4:   "mat_wood_light"
        case .d6:   "mat_marble_white"
        case .d8:   "mat_marble_green"
        case .d10:  "mat_copper"
        case .d20:  "mat_steel"
        }
    }
}

// MARK: - Pool

struct PooledDie: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: DieType
}

// MARK: - Rolls & history (SwiftData)

struct DieRoll: Codable, Hashable {
    var type: DieType
    var value: Int

    /// Coin shows 0/1; dice show their number.
    var display: String {
        type == .coin ? (value == 0 ? "0" : "1") : String(value)
    }
}

@Model
final class ThrowResult {
    var timestamp: Date
    var total: Int
    var rolls: [DieRoll]

    init(timestamp: Date = .now, total: Int, rolls: [DieRoll]) {
        self.timestamp = timestamp
        self.total = total
        self.rolls = rolls
    }

    /// "2d6 + d20" style summary of the thrown pool.
    var poolLabel: String {
        var counts: [DieType: Int] = [:]
        var order: [DieType] = []
        for roll in rolls {
            if counts[roll.type] == nil { order.append(roll.type) }
            counts[roll.type, default: 0] += 1
        }
        return order
            .map { counts[$0]! > 1 ? "\(counts[$0]!)\($0.label)" : $0.label }
            .joined(separator: " + ")
    }
}

// MARK: - Color helpers

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}
