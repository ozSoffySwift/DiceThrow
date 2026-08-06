import SwiftUI
import SwiftData
import simd

/// A past throw's total with a stable identity, so the results strip can
/// animate insertions/shifts correctly instead of just diffing raw values.
private struct SessionTotal: Identifiable {
    let id = UUID()
    let value: Int
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ThrowResult.timestamp, order: .reverse) private var history: [ThrowResult]

    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("shakeEnabled") private var shakeEnabled = true
    @AppStorage("sensitivity") private var sensitivity = "medium"
    @AppStorage("poolData") private var poolData = Data()

    @AppStorage("hasShownShakeHint") private var hasShownShakeHint = false

    @State private var pool: [PooledDie] = []
    @State private var currentTotal: Int?
    @State private var sessionTotals: [SessionTotal] = []
    @State private var dockOpen = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showWelcomeHint = false
    @State private var animatedTotal: Int?
    @State private var countUpTask: Task<Void, Never>?
    @State private var totalFlash = false

    @StateObject private var table = DiceTable()
    @StateObject private var shake = ShakeMonitor()

    private let maxPool = 10
    private let silverGradient = LinearGradient(
        colors: [Color(hex: 0xC7C9CC), Color(hex: 0x8E8E93)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // Authentic wood-grain border that fills to the iPhone screen edges (behind everything).
            WoodBorderView()
                .zIndex(0)

            DiceTableView(
                table: table,
                onTapFelt: { point in
                    if dockOpen { dockOpen = false; return }
                    throwDice(from: point, source: .tapFelt)
                },
                onTapDie: { id in
                    if dockOpen { dockOpen = false; return }
                    if let position = table.diePosition(id) {
                        throwDice(from: position, source: .tapDie)
                    }
                },
                onRemoveDie: { id in
                    if let die = pool.first(where: { $0.id == id }) {
                        Analytics.dieRemoved(die.type, method: "drag_off",
                                             poolSizeAfter: pool.count - 1)
                    }
                    pool.removeAll { $0.id == id }
                },
                onDirectionalThrow: { direction in
                    if dockOpen { dockOpen = false; return }
                    dismissWelcomeHint()
                    Analytics.diceThrown(source: .drag, pool: pool)
                    beginNewThrow()
                    table.throwAllDirectional(direction)
                }
            )
            .ignoresSafeArea()
            .zIndex(1)

            resultsColumn
                .zIndex(2)
            emptyStateOverlay
                .zIndex(2)
            bottomControls
                .zIndex(3)
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $showHistory) { HistoryView() }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(onDeleteHistory: {
                sessionTotals.removeAll()
                currentTotal = nil
            })
        }
        .onAppear {
            loadPool()
            table.soundEnabled = { soundEnabled }
            table.onSettled = { outcome in
                // Feedback first, persistence second: the SwiftData insert runs
                // synchronously on the main actor, so doing it ahead of the haptic
                // put a (small, history-size-dependent) stall right in the path
                // between the dice stopping and the user feeling the result.
                currentTotal = outcome.total
                Haptics.impact(.heavy)
                animateCountUp(to: outcome.total)
                modelContext.insert(ThrowResult(total: outcome.total, rolls: outcome.rolls))
                Analytics.throwSettled(total: outcome.total,
                                       poolSize: outcome.rolls.count,
                                       settleMs: Int(outcome.settleDuration * 1000),
                                       timedOut: outcome.timedOut)
            }
            table.syncPool(pool)
            shake.onShake = {
                dismissWelcomeHint()
                throwDice(from: nil, source: .shake)
            }
            updateShakeMonitor()
            syncAnalyticsUserProperties()
            Analytics.screenView("dice_table")
            if history.isEmpty && !hasShownShakeHint {
                hasShownShakeHint = true
                withAnimation(.easeIn(duration: 0.4)) {
                    showWelcomeHint = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    dismissWelcomeHint()
                }
            }
        }
        .onChange(of: pool) { _, newPool in
            table.syncPool(newPool)
            savePool()
            syncAnalyticsUserProperties()
        }
        .onChange(of: shakeEnabled) { updateShakeMonitor(); syncAnalyticsUserProperties() }
        .onChange(of: soundEnabled) { syncAnalyticsUserProperties() }
        .onChange(of: hapticsEnabled) { syncAnalyticsUserProperties() }
        .onChange(of: sensitivity) {
            shake.setSensitivity(sensitivity)
            syncAnalyticsUserProperties()
        }
        .onChange(of: scenePhase) { updateShakeMonitor() }
    }

    // MARK: - HUD pieces

    /// Stats-over-TOTAL box docked to the left screen edge at middle height,
    /// with the last 6 throws stacked in a column beneath it running down
    /// toward the bottom — most recent directly under TOTAL, sliding down
    /// the instant a new throw starts (stable per-item IDs via SessionTotal
    /// are what make the slide animate at all).
    private var resultsColumn: some View {
        VStack(alignment: .center, spacing: 6) {
            VStack(spacing: 0) {
                // Mean / min / max of the CURRENT POOL's possible totals
                // (not past results) — recomputed the instant a die is
                // added or removed, so it's a live "what can this pool
                // roll" readout rather than a history stat. Stacked above
                // TOTAL rather than beside it, so the box stays docked to
                // the edge instead of stretching wide.
                if !pool.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        statLine("MEAN", meanText)
                        statLine("MIN", "\(minTotal)")
                        statLine("MAX", "\(maxTotal)")
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color(hex: 0xD4AF37).opacity(0.3))
                        .frame(height: 1)
                        .padding(.horizontal, 4)
                }

                VStack(spacing: 1) {
                    Text("TOTAL")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color(hex: 0xD4AF37).opacity(0.85))
                        .lineLimit(1)
                    Text(totalDisplay)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(totalFlash ? Color(hex: 0xFFE9A8) : .white)
                        .scaleEffect(totalFlash ? 1.22 : 1.0)
                        .shadow(color: Color(hex: 0xD4AF37).opacity(totalFlash ? 0.9 : 0), radius: 8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minWidth: 44, alignment: .center)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Exact width, not minWidth: this stops the infinite-width
            // proposal from resultsColumn's own edge-docking frame (below)
            // from reaching the divider/inner frames and stretching them
            // across the whole screen. Trimmed to hug the content tightly
            // instead of leaving dead space on the right.
            .frame(width: 65)
            .background(Color(hex: 0x0A0B0F).opacity(0.82))
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 10, topTrailingRadius: 10)
            )
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 10, topTrailingRadius: 10)
                    .stroke(Color(hex: 0xD4AF37).opacity(0.45), lineWidth: 1)
            )

            ForEach(Array(sessionTotals.prefix(6))) { item in
                Text("\(item.value)")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: 0x0A0B0F).opacity(0.82))
                    .padding(.vertical, 2)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .offset(y: 100)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea(edges: .leading)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0xD4AF37).opacity(0.7))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var emptyStateOverlay: some View {
        Group {
            if pool.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "dice.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Tap the + button to build your dice pool")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .allowsHitTesting(false)
            } else if showWelcomeHint {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .medium))
                    Text("Shake device to throw dice")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color(hex: 0xE8D5A8))
                .padding(.vertical, 20)
                .padding(.horizontal, 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x4A3218), Color(hex: 0x2E1D0E)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: 0xB08D4F).opacity(0.7), lineWidth: 1.5)
                        .padding(3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .rotationEffect(.degrees(-1.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .allowsHitTesting(false)
            }
        }
    }

    /// A single evenly-spaced row along the bottom: History, Settings,
    /// Reset, Add — in that order, History sitting under the results
    /// column on the left edge.
    private var bottomControls: some View {
        VStack {
            Spacer()
            HStack {
                // History.
                Button {
                    Analytics.historyOpened(throwCount: history.count)
                    Analytics.screenView("history")
                    showHistory = true
                } label: {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
                .disabled(history.isEmpty)
                .opacity(history.isEmpty ? 0.35 : 1)

                Spacer()

                // Settings.
                Button {
                    Analytics.screenView("settings")
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }

                Spacer()

                // Reset.
                Button {
                    if dockOpen { dockOpen = false }
                    Analytics.poolReset(poolSizeBefore: pool.count)
                    pool.removeAll()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.red.opacity(0.25))
                        .clipShape(Circle())
                }
                .disabled(pool.isEmpty)
                .opacity(pool.isEmpty ? 0.4 : 1)

                Spacer()

                // Add-die FAB, with the dock fan of die types anchored
                // directly above it so it always tracks the button's
                // position in this evenly-spaced row.
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dockOpen.toggle()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x0A0B0F))
                        .frame(width: 56, height: 56)
                        .background(silverGradient)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        .rotationEffect(.degrees(dockOpen ? 45 : 0))
                }
                .overlay(alignment: .bottom) {
                    dockFan
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    /// macOS-dock-style fan of die types, anchored above the Add button.
    private var dockFan: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(DieType.allCases.enumerated()), id: \.element) { index, type in
                Button {
                    addDie(type)
                } label: {
                    ZStack {
                        if let uiImage = dockMaterialImage(type) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())
                        } else {
                            type.accent
                        }
                        Circle()
                            .fill(Color.black.opacity(0.38))
                        Group {
                            if type == .coin {
                                Image(systemName: "circle.circle.fill")
                                    .font(.system(size: 18, weight: .bold))
                            } else {
                                Text(type.label)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(Color(hex: 0xF2E7CC))
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 5)
                }
                // 52pt rather than 58: with seven die types the fan is tall enough
                // that the top entry would otherwise crowd the results column.
                .offset(y: dockOpen ? -CGFloat(index + 1) * 52 : 0)
                .scaleEffect(dockOpen ? 1 : 0.3, anchor: .bottom)
                .opacity(dockOpen ? 1 : 0)
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.7)
                        .delay(Double(index) * 0.03),
                    value: dockOpen
                )
                .allowsHitTesting(dockOpen)
            }
        }
    }

    // MARK: - Actions & state

    private var totalDisplay: String {
        if table.rolling { return "…" }
        if let animatedTotal { return "\(animatedTotal)" }
        if let currentTotal { return "\(currentTotal)" }
        return "—"
    }

    /// Called the instant a new throw starts (not when it settles): whatever
    /// total was showing immediately slides down to become the newest entry
    /// in the history column, so TOTAL clears to "…" and the old number
    /// reappears right underneath in the same motion, rather than waiting
    /// for the new roll to finish.
    private func beginNewThrow() {
        countUpTask?.cancel()
        animatedTotal = nil
        totalFlash = false
        guard let previous = currentTotal else { return }
        currentTotal = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            sessionTotals.insert(SessionTotal(value: previous), at: 0)
            sessionTotals = Array(sessionTotals.prefix(6))
        }
    }

    /// Mean/min/max possible total for the CURRENT POOL — e.g. two d6 can
    /// never total less than 2, so min/max are summed from each die's own
    /// face range rather than read off past throws (which would read 0
    /// before anything's been rolled). Recomputes automatically whenever
    /// `pool` changes, since SwiftUI re-evaluates these on every body pass.
    private var meanText: String {
        guard !pool.isEmpty else { return "—" }
        let mean = pool.reduce(0.0) { $0 + $1.type.meanFaceValue }
        return String(format: "%.1f", mean)
    }

    private var minTotal: Int {
        pool.reduce(0) { $0 + $1.type.minFaceValue }
    }

    private var maxTotal: Int {
        pool.reduce(0) { $0 + $1.type.maxFaceValue }
    }

    /// Count-up from 1 to the rolled total that starts fast and audibly
    /// slows down right before landing — true linear deceleration (constant
    /// braking, like a wheel spinning down), not just an eased curve — then
    /// flashes the total to mark it as final.
    private func animateCountUp(to total: Int) {
        countUpTask?.cancel()
        guard total > 1 else {
            animatedTotal = total
            flashTotal()
            return
        }
        countUpTask = Task { @MainActor in
            let steps = min(total, 18)
            let duration = 0.45
            let stepDelay = duration / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                let t = Double(i) / Double(steps)
                // Quadratic ease-out sampled at UNIFORM time steps is exactly
                // the position curve of an object decelerating at a constant
                // rate — i.e. counting speed drops in a straight line to zero.
                let eased = 1 - (1 - t) * (1 - t)
                animatedTotal = i == steps ? total : max(1, Int((eased * Double(total)).rounded()))
                try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            flashTotal()
        }
    }

    /// Brief bright scale-up on the TOTAL text to mark the result as final.
    private func flashTotal() {
        withAnimation(.easeOut(duration: 0.09)) {
            totalFlash = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                totalFlash = false
            }
        }
    }

    private func throwDice(from origin: simd_float3?, source: Analytics.ThrowSource) {
        guard !pool.isEmpty else { return }
        dismissWelcomeHint()
        Analytics.diceThrown(source: source, pool: pool)
        beginNewThrow()
        table.throwAll(from: origin)
        Haptics.impact(.medium)
    }

    private func dismissWelcomeHint() {
        guard showWelcomeHint else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            showWelcomeHint = false
        }
    }

    private func dockMaterialImage(_ type: DieType) -> UIImage? {
        guard let url = Bundle.main.url(forResource: type.materialImageName, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func addDie(_ type: DieType) {
        if pool.count < maxPool {
            pool.append(PooledDie(type: type))
            Analytics.dieAdded(type, poolSizeAfter: pool.count)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            dockOpen = false
        }
    }

    private func loadPool() {
        if let decoded = try? JSONDecoder().decode([PooledDie].self, from: poolData),
           !poolData.isEmpty {
            pool = decoded
        } else if pool.isEmpty {
            pool = [PooledDie(type: .d6), PooledDie(type: .d6)]
        }
    }

    private func savePool() {
        poolData = (try? JSONEncoder().encode(pool)) ?? Data()
    }

    private func syncAnalyticsUserProperties() {
        Analytics.updateUserProperties(pool: pool,
                                       soundEnabled: soundEnabled,
                                       hapticsEnabled: hapticsEnabled,
                                       shakeEnabled: shakeEnabled,
                                       sensitivity: sensitivity)
    }

    private func updateShakeMonitor() {
        if shakeEnabled && scenePhase == .active {
            shake.start(sensitivity: sensitivity)
        } else {
            shake.stop()
        }
    }
}
