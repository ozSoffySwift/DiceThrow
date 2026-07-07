import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ThrowResult.timestamp, order: .reverse) private var history: [ThrowResult]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if history.isEmpty {
                Spacer()
                Text("No throws yet.\nRoll some dice and they'll show up here.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                ScrollView {
                    chart
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedByDay, id: \.label) { group in
                            Text(group.label.uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.top, 16)
                            ForEach(group.items) { item in
                                HistoryRow(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(hex: 0x0A0B0F))
    }

    private var topBar: some View {
        HStack {
            Text("History")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0xE8EAED))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC7C9CC))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0xC7C9CC).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xC7C9CC).opacity(0.12)).frame(height: 1)
        }
    }

    /// Last 30 totals, oldest → newest, gold bars. Horizontally scrollable
    /// since 30 bars don't fit one screen width at a readable bar size.
    private var chart: some View {
        let recent = Array(history.prefix(30).reversed())
        let slotWidth: CGFloat = 42
        return ScrollView(.horizontal, showsIndicators: false) {
            Chart(Array(recent.enumerated()), id: \.offset) { index, item in
                BarMark(
                    x: .value("Throw", index),
                    y: .value("Total", item.total),
                    width: .fixed(26)
                )
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: 0xD4AF37), Color(hex: 0x8A6D1F)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .cornerRadius(4)
                .annotation(position: .top, spacing: 3) {
                    Text("\(item.total)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: max(CGFloat(recent.count) * slotWidth, 100), height: 110)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xC7C9CC).opacity(0.1)).frame(height: 1)
        }
    }

    private struct DayGroup {
        let label: String
        let items: [ThrowResult]
    }

    private var groupedByDay: [DayGroup] {
        var groups: [DayGroup] = []
        for item in history {
            let label = dayLabel(item.timestamp)
            if let last = groups.indices.last, groups[last].label == label {
                groups[last] = DayGroup(label: label, items: groups[last].items + [item])
            } else {
                groups.append(DayGroup(label: label, items: [item]))
            }
        }
        return groups
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: .now), date > weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct HistoryRow: View {
    let item: ThrowResult

    /// Mean/min/max across this one throw's individual die values (not
    /// across throws), so the row shows how spread-out that particular
    /// roll was.
    private var rollStats: (mean: Double, min: Int, max: Int) {
        let values = item.rolls.map(\.value)
        let mean = Double(values.reduce(0, +)) / Double(max(values.count, 1))
        return (mean, values.min() ?? 0, values.max() ?? 0)
    }

    var body: some View {
        let stats = rollStats
        VStack(alignment: .leading, spacing: 4) {
            Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline) {
                Text(item.poolLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE8EAED))
                Spacer()
                Text("TOTAL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color(hex: 0xD4AF37).opacity(0.75))
                Text("\(item.total)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xC7C9CC))
            }
            // Mean/min/max of this throw's individual die values.
            HStack(spacing: 12) {
                statChip("MEAN", String(format: "%.1f", stats.mean))
                statChip("MIN", "\(stats.min)")
                statChip("MAX", "\(stats.max)")
            }
            // Per-die result chips.
            FlowChips(rolls: item.rolls)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xC7C9CC).opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct FlowChips: View {
    let rolls: [DieRoll]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(rolls.enumerated()), id: \.offset) { _, roll in
                // Dark text — several die accents (d6 white, coin light gray,
                // d4 yellow) are too light for white text to stay legible.
                Text("\(roll.type.label): \(roll.display)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x1A1508))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(roll.type.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
