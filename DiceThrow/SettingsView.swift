import SwiftUI
import SwiftData
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("shakeEnabled") private var shakeEnabled = true
    @AppStorage("sensitivity") private var sensitivity = "medium"

    @State private var confirmingDelete = false

    var onDeleteHistory: () -> Void = {}

    private let purple = Color(hex: 0x7B68EE)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    group {
                        toggleRow("Sound Effects", isOn: $soundEnabled)
                        divider
                        toggleRow("Haptics", isOn: $hapticsEnabled)
                    }
                    group {
                        toggleRow("Shake to Throw", isOn: $shakeEnabled)
                        if shakeEnabled {
                            divider
                            sensitivityRow
                        }
                    }
                    group {
                        Button {
                            confirmingDelete = true
                        } label: {
                            Text("Delete History")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xE5484D))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(hex: 0xE5484D).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(hex: 0xE5484D).opacity(0.45), lineWidth: 1)
                                )
                        }
                    }
                    group {
                        Button {
                            requestReview()
                        } label: {
                            Text("★ Rate This App")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x0A84FF))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(hex: 0xC7C9CC).opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    group {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dice Throw: 3D Emulator v1.0")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                            Text("Developed by Oz Soffy")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(Color(hex: 0x0A0B0F))
        .confirmationDialog("Delete all throw history?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete History", role: .destructive) {
                try? modelContext.delete(model: ThrowResult.self)
                onDeleteHistory()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("Settings")
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

    private func group(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .padding(16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: 0xC7C9CC).opacity(0.08)).frame(height: 1)
            }
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0xC7C9CC).opacity(0.06)).frame(height: 1)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: 0xE8EAED))
        }
        .tint(purple)
        .padding(.vertical, 12)
    }

    private var sensitivityRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensitivity")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: 0xE8EAED))
            HStack(spacing: 8) {
                Text("Low")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Slider(value: sensitivityIndex, in: 0...2, step: 1)
                    .tint(purple)
                Text("High")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.vertical, 12)
    }

    private var sensitivityIndex: Binding<Double> {
        Binding(
            get: {
                switch sensitivity {
                case "low": 0
                case "high": 2
                default: 1
                }
            },
            set: { newValue in
                sensitivity = ["low", "medium", "high"][Int(newValue)]
            }
        )
    }
}
