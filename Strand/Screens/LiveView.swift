import SwiftUI
#if os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Live — the connected strap in real time. Built on the shared design system
/// (ScreenScaffold chrome, StrandPalette, StrandFont) so it lines up pixel-for-pixel
/// with every other screen instead of the old standalone Milestone-1 layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Cross-screen navigation — drives the "Manage devices" affordance to the first-class Devices
    /// manager (where bands are paired / switched). The shell (sidebar on macOS, a sheet on iOS) routes
    /// the request; LiveView never needs to know which.
    @EnvironmentObject private var router: NavRouter

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// Maps the picked strap model to the HRV-reading source so the spot caveat is honest (#537): a
    /// WHOOP 5/MG's R-R is optical PPG (noisier), a WHOOP 4 is electrical R-R. Mirrors the Android
    /// `LiveScreen` mapping.
    private var hrvSnapshotSource: SpotHrvReading.Source {
        switch selectedModel {
        case .whoop5mg: return .opticalPPG
        case .whoop4:   return .chestStrap
        }
    }

    /// Effort display scale (#268) — routes the live + saved workout Effort read-outs. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { live.connected && live.bonded }

    /// The display name of the active device from the registry ("WHOOP", a strap's nickname, …) — what
    /// the user is connected to, or would connect to. Falls back to "WHOOP" before the registry opens or
    /// when none is resolvable, keeping the WHOOP-first tone. Drives the active-device readout + copy.
    private var activeDeviceName: String {
        guard let registry = model.deviceRegistry,
              let active = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        else { return "WHOOP" }
        return active.displayName
    }

    /// The live HR zone for the focal readout's colour world (presentation only — same shared
    /// `HRZones` model the live-workout screen uses). 0 = below Zone 1 / no HR yet.
    private var liveZone: Int {
        guard let bpm = displayHR else { return 0 }
        return HRZones.zones(maxHR: Double(model.profile.hrMax)).zoneNumber(forBPM: Double(bpm))
    }

    /// The focal HR ring / numeral colour: the live HR-zone hue when streaming, the Effort world
    /// otherwise — so the console reads in the Effort (amber) world like every workouts/live surface.
    private var hrTint: Color {
        guard displayHR != nil else { return StrandPalette.textTertiary }
        return liveZone >= 1 ? StrandPalette.hrZoneColor(liveZone) : StrandPalette.effortColor
    }

    /// Drives the focal HR ring's gentle pulse — toggled on every new HR value so the ring "beats".
    @State private var heartPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live workout mode (#238) — presents the full in-exercise screen while a manual workout is
    /// active. Auto-opens when a workout begins; closing just hides it (the workout keeps recording).
    @State private var showLiveWorkout = false
    @State private var showStartSport = false

    /// Manual HRV snapshot (#127) — presents the "Take an HRV reading" screen as a sheet. Entry sits in
    /// the Session console and is only enabled while bonded (the reading needs the live R-R stream).
    @State private var showHRVSnapshot = false

    var body: some View {
        ScreenScaffold(title: "Live Body Console",
                       subtitle: "Current physiology, strap trust, and session controls in one working view.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                consoleHeader
                // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
                // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
                // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
                if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                // Primary Connect affordance, surfaced ABOVE the fold whenever there's no link. The real
                // Scan & Connect control otherwise lives in `controls` (below the Signal Trust grid), so
                // an offline user saw only inert copy up top. Gated purely on `!live.connected`, so it
                // disappears the instant the radio connects. Shared with macOS — it reuses `scanButton`,
                // which the wide layout already renders in `controls`.
                if !live.connected { offlineConnectCallout }
                bodyConsole
                // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
                // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
                // still works — this is informational, not an error — so it sits right under the readout in
                // a calm accent treatment rather than the amber warning banners above.
                if Self.shouldShowStandardHRNote(live.standardHRMode) {
                    standardHRNote(live.standardHRMode ?? "")
                }
                signalTrustRail
                sessionConsole
                // Show the strap picker whenever we're not actively streaming, so a user with both a
                // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
                // sticky across disconnects — so after the first pairing the picker vanished for good.)
                if !activeConnection { modelPicker }
                controls
                manageDevicesRow
                logCard
            }
        }
        .onAppear { refreshLiveSession(); consumeActiveWorkoutRequest() }
        .onDisappear { model.stopRealtimeHR() }
        // A fresh bond/connection re-arms the BLE stream (Apple must re-send startRealtime on a new
        // connection) WITHOUT bumping the ref-count — `refreshLiveSession`'s `startRealtimeHR` already
        // counted this screen once on `.onAppear`, balanced by the single `stopRealtimeHR` above.
        // Re-counting here (multiple bonded/connected events per appearance, one disappear) would leave
        // the stream stuck armed after leaving Live (#681 ref-count balance).
        .onChangeCompat(of: live.bonded) { _ in reconnectLiveSession() }
        .onChangeCompat(of: live.connected) { _ in reconnectLiveSession() }
        .onChangeCompat(of: displayHR) { _ in
            // Reduce Motion: keep the ring at its resting scale — the HR number still
            // updates via its own .contentTransition(.numericText()), so live HR is
            // fully functional; only the cosmetic per-beat pulse is suppressed.
            guard !reduceMotion else { return }
            withAnimation(StrandMotion.pulse) { heartPulse.toggle() }
        }
        // Live workout mode (#238): open the in-exercise screen the moment a workout starts.
        .onChangeCompat(of: model.activeWorkout != nil) { active in if active { showLiveWorkout = true } }
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model)
                .environmentObject(live)
        }
        // Pick a named sport before starting (#519) — the live workout view then opens
        // off the activeWorkout change above, so no extra navigation is needed here.
        .sheet(isPresented: $showStartSport) {
            StartWorkoutSheet { name in model.startWorkout(sport: name) }
        }
        // Manual HRV snapshot (#127) — a still, seated 60s R-R reading.
        .sheet(isPresented: $showHRVSnapshot) {
            // Tell the reading where its R-R is coming from so the caveat is honest (#537): a WHOOP 5/MG
            // derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is
            // electrical R-R. Driven off the picked strap model, mirroring the Android twin.
            HRVSnapshotView(onClose: { showHRVSnapshot = false }, source: hrvSnapshotSource)
                .environmentObject(model)
                .environmentObject(live)
        }
    }

    // MARK: - Console header

    /// The console's top band: the connection pill + a connection-mode badge (+ a live SYNCING badge
    /// while a history offload runs), with battery / worn / last-sync stats pushed to the trailing edge.
    private var consoleHeader: some View {
        NoopCard(padding: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    connectionPill
                    if showsModeBadge {
                        SourceBadge(connectionModeBadge, tint: connectionModeColor)
                    }
                    if live.backfilling {
                        SourceBadge("SYNCING \(live.syncChunksThisSession)", tint: StrandPalette.metricCyan)
                    }
                    Spacer(minLength: 8)
                    headerStats
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        connectionPill
                        if showsModeBadge {
                            SourceBadge(connectionModeBadge, tint: connectionModeColor)
                        }
                        if live.backfilling {
                            SourceBadge("SYNCING \(live.syncChunksThisSession)", tint: StrandPalette.metricCyan)
                        }
                        Spacer(minLength: 0)
                    }
                    headerStats
                }
            }
        }
    }

    private var headerStats: some View {
        HStack(spacing: 16) {
            headerStat("Device", activeDeviceName)
            headerStat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—")
            headerStat("Worn", activeConnection ? (live.worn ? "Yes" : "No") : "—")
            headerStat("Last sync", lastSyncLabel)
        }
    }

    private func headerStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var connectionModeBadge: LocalizedStringKey {
        if activeConnection && live.encryptedBond { return "FULL BOND" }
        if activeConnection { return "LIVE HR ONLY" }
        if live.connected { return "CONNECTING" }
        if live.encryptedBond { return "PAIRED" }
        return "OFFLINE"
    }

    /// Whether to render the connection-mode SourceBadge. When fully offline the `connectionPill`
    /// already reads "● Disconnected" in metricRose, so the duplicate rose "OFFLINE" badge is pure
    /// redundancy — suppress it. We keep the badge for every informative state (FULL BOND / LIVE HR
    /// ONLY / CONNECTING / PAIRED), where it adds signal beyond the pill. The gate matches exactly the
    /// branch where `connectionModeBadge` would return "OFFLINE".
    private var showsModeBadge: Bool {
        !(!activeConnection && !live.connected && !live.encryptedBond)
    }

    private var connectionModeColor: Color {
        if activeConnection && live.encryptedBond { return StrandPalette.accent }
        if activeConnection || live.connected { return StrandPalette.statusWarning }
        return StrandPalette.metricRose
    }

    private var connectionPill: some View {
        // Distinguish a GENUINE encrypted bond from the 5/MG live-HR shortcut that flips `bonded` true
        // over the unbonded standard profile (#69): green "Bonded · streaming" only when encryptedBond,
        // amber "Live HR (not fully paired)" otherwise. The pairingHintBanner below gives the how-to.
        let (label, color): (String, Color) =
            (activeConnection && live.encryptedBond) ? ("Bonded · streaming", StrandPalette.accent)
            : activeConnection ? ("Live HR (not fully paired)", StrandPalette.statusWarning)
            : live.connected ? ("Connected", StrandPalette.statusWarning)
            : live.encryptedBond ? ("Paired · idle", StrandPalette.statusWarning)
            : ("Disconnected", StrandPalette.metricRose)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    // MARK: - Body console (focal HR + live physiology)

    /// The console's centrepiece: a pulsing focal HR ring beside a live-physiology stack (R-R strip,
    /// rolling RMSSD, last frame/event). Side-by-side on a wide window (Mac), stacked on a narrow one
    /// (iPhone) via ViewThatFits. The whole console floats over an Effort-tinted scenic hero so the live
    /// readout reads like a Bevel hero, and the card carries the Effort wash.
    private var bodyConsole: some View {
        NoopCard(padding: NoopMetrics.space5, tint: StrandPalette.effortColor) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: NoopMetrics.space6) {
                    heartReadout
                        .frame(minWidth: 260, maxWidth: 340)
                    Divider().overlay(StrandPalette.hairline)
                    physiologyStack
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 18) {
                    heartReadout
                    Divider().overlay(StrandPalette.hairline)
                    physiologyStack
                }
            }
        }
        .background {
            ScenicHeroBackground(domain: .effort)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    private var heartReadout: some View {
        let tint = hrTint
        return VStack(alignment: .center, spacing: NoopMetrics.space2) {
            Text("HEART RATE")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            ZStack {
                // Crisp, flat zone ring that "beats" by a subtle scale + opacity step — NO glow/bloom
                // (the prior blurred halo is removed per the design reset). The outer ring is the live
                // pulse, the inner hairline is a static frame; both stay sharp and high-contrast.
                Circle()
                    .stroke((displayHR == nil ? StrandPalette.hairline : tint)
                        .opacity(heartPulse ? 0.55 : 0.28), lineWidth: 2.5)
                    .scaleEffect(heartPulse ? 1.05 : 0.97)
                Circle()
                    .stroke(StrandPalette.hairline, lineWidth: 1)
                    .padding(10)
                VStack(spacing: 0) {
                    // The big focal HR numeral ticks up to the live value (the hero number); a crisp
                    // em-dash while there's no HR yet. Reduce Motion snaps it (CountUpText handles that).
                    if let bpm = displayHR {
                        CountUpText(value: Double(bpm),
                                    format: { "\(Int($0.rounded()))" },
                                    font: StrandFont.rounded(96, weight: .semibold),
                                    color: tint)
                    } else {
                        Text("—")
                            .font(StrandFont.rounded(96, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text("bpm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if liveZone >= 1 {
                        Text("ZONE \(liveZone)")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(tint)
                            .padding(.top, NoopMetrics.space1)
                    }
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Heart rate not available")
            Text(signalTrustSummary)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var physiologyStack: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE PHYSIOLOGY")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(connectionModeDetail)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                if let rmssd = rollingRMSSD {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RMSSD")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(Int(rmssd.rounded())) ms")
                            .font(StrandFont.number(24))
                            .foregroundStyle(StrandPalette.metricCyan)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Rolling RMSSD \(Int(rmssd.rounded())) milliseconds")
                }
            }
            rrStrip
            HStack(spacing: NoopMetrics.gap) {
                // Offline: show a muted "Offline" word (dimmed to textTertiary) instead of three bare
                // accent-coloured em-dashes that read as broken live readouts. Once there's an active
                // stream the real values (and their cyan/green/amber accents) return.
                liveProofMetric("R-R", activeConnection ? rrSummary : "Offline",
                                StrandPalette.metricCyan, offline: !activeConnection)
                liveProofMetric("Frame", activeConnection ? (live.lastFrameType ?? "—") : "Offline",
                                StrandPalette.accent, offline: !activeConnection)
                liveProofMetric("Event", activeConnection ? (live.lastEvent ?? "—") : "Offline",
                                StrandPalette.statusWarning, offline: !activeConnection)
            }
        }
    }

    /// A compact bar strip of the recent R-R buffer — the proof the console is genuinely live (a
    /// single HR number can look frozen; a moving R-R strip can't). Empty state shows muted ticks.
    private var rrStrip: some View {
        let values = Array(live.rrRecent.suffix(18))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 5) {
                if values.isEmpty {
                    ForEach(0..<18, id: \.self) { _ in
                        Capsule().fill(StrandPalette.hairline).frame(width: 6, height: 18)
                    }
                } else {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, rr in
                        Capsule()
                            .fill(StrandPalette.metricCyan.opacity(0.35 + min(0.45, Double(rr % 180) / 400.0)))
                            .frame(width: 6, height: rrBarHeight(rr))
                    }
                }
            }
            .accessibilityHidden(true)
            Text(values.isEmpty
                 ? "Waiting for R-R intervals."
                 : "Recent intervals: " + values.suffix(5).map(String.init).joined(separator: " · ") + " ms")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// One R-R / Frame / Event proof tile. When `offline` is true the value is dimmed to textTertiary
    /// (regardless of the passed accent) so an idle tile reads as a muted empty state rather than a
    /// broken live readout in cyan/green/amber — matching the rrStrip's "Waiting for R-R intervals."
    /// treatment just above. The callers pass a word ("Offline") instead of a bare em-dash in that case.
    private func liveProofMetric(_ label: String, _ value: String, _ tint: Color,
                                 offline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(offline ? StrandPalette.textTertiary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NoopMetrics.rowSpacing)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func rrBarHeight(_ rr: Int) -> CGFloat {
        let clamped = min(max(rr, 420), 1_180)
        return 16 + CGFloat(clamped - 420) / 760 * 42
    }

    /// A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
    /// clinical figure; it's blanked on disconnect by clearBiometrics). nil until ≥3 intervals land.
    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var rrSummary: String {
        guard let last = live.rr.last else { return "—" }
        return "\(last) ms"
    }

    private var signalTrustSummary: String {
        if activeConnection && live.encryptedBond { return "Encrypted stream — deep controls and history sync available." }
        if activeConnection { return "Live heart rate is flowing; full strap controls need an encrypted bond." }
        if live.connected { return "Connected, waiting for a streaming state." }
        // The actionable "Scan and connect…" CTA now lives in `offlineConnectCallout` above the fold, so
        // this ring caption stays a calm empty-state descriptor rather than a second, competing CTA.
        return "Live heart rate appears here once a strap is connected."
    }

    private var connectionModeDetail: String {
        if activeConnection && live.encryptedBond { return "Full strap stream is active." }
        if activeConnection { return "Heart rate stream is active." }
        if live.connected { return "Radio connected, stream not yet trusted." }
        return "No live stream."
    }

    // MARK: - Signal trust

    /// The "Signal Trust" rail — one tile per signal that has to be current for the console to be
    /// trustworthy (HR, R-R, connection, history sync, battery, wear). Each tile's value AND tint are
    /// gated on a live link where it matters, so an offline console never shows a false-green signal.
    private var signalTrustRail: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Signal Trust", overline: "Proof that the console is current")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                ForEach(Array(signalTiles.enumerated()), id: \.element.id) { idx, tile in
                    SignalTrustTile(tile: tile)
                        .staggeredAppear(index: idx)
                }
            }
        }
    }

    private var signalTiles: [SignalTrustTile.Model] {
        [
            .init(title: "Heart rate",
                  value: displayHR.map { "\($0) bpm" } ?? "Missing",
                  detail: activeConnection ? "Streaming now" : "No active stream",
                  icon: "waveform.path.ecg",
                  tint: displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent),
            .init(title: "R-R intervals",
                  value: live.rrRecent.isEmpty ? "Missing" : "\(live.rrRecent.count) recent",
                  detail: rollingRMSSD.map { "RMSSD \(Int($0.rounded())) ms" } ?? "Needs interval frames",
                  icon: "point.3.connected.trianglepath.dotted",
                  tint: live.rrRecent.isEmpty ? StrandPalette.textTertiary : StrandPalette.metricCyan),
            .init(title: "Connection",
                  value: activeConnection && live.encryptedBond ? "Encrypted" : activeConnection ? "Partial" : live.connected ? "Connected" : "Offline",
                  detail: activeConnection && live.encryptedBond ? "Controls unlocked" : "Standard HR is not a full bond",
                  icon: "lock.shield",
                  tint: connectionModeColor),
            .init(title: "History sync",
                  value: live.backfilling ? "\(live.syncChunksThisSession) chunks" : lastSyncLabel,
                  detail: syncDetail,
                  icon: "clock.arrow.circlepath",
                  tint: live.backfilling ? StrandPalette.metricCyan : StrandPalette.textSecondary),
            .init(title: "Battery",
                  value: live.batteryPct.map { "\(Int($0))%" } ?? "Unknown",
                  detail: live.charging == true ? "Charging" : "Last reported by strap",
                  icon: "battery.75percent",
                  tint: batteryTint),
            // Wear is only trustworthy on a live link: `worn` defaults true (LiveState) and is only
            // updated by WRIST_ON/OFF events, so while OFFLINE it would otherwise read a false-green
            // "On wrist". Gate the value AND tint on activeConnection (triage fix for PR#191).
            .init(title: "Wear state",
                  value: activeConnection ? (live.worn ? "On wrist" : "Off wrist") : "Unknown",
                  detail: activeConnection ? (live.worn ? "Eligible for live physiology" : "Wear the strap for scoring") : "Connect to read wear state",
                  icon: "sensor.tag.radiowaves.forward",
                  tint: !activeConnection ? StrandPalette.textTertiary : live.worn ? StrandPalette.accent : StrandPalette.statusWarning)
        ]
    }

    private var batteryTint: Color {
        guard let pct = live.batteryPct else { return StrandPalette.textTertiary }
        if pct <= 15 { return StrandPalette.metricRose }
        if pct <= 30 { return StrandPalette.statusWarning }
        return StrandPalette.accent
    }

    private var lastSyncLabel: String {
        guard let ts = live.lastSyncedAt else { return "Never" }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var syncDetail: String {
        if let err = live.lastSyncError { return err }
        if live.backfilling { return "\(live.decodedChunksThisSession) decoded, \(live.consoleChunksThisSession) console" }
        return live.lastSyncedAt == nil ? "No completed offload yet" : "Last offload completed"
    }

    // MARK: - Session console (record / inspect the current stream)

    @ViewBuilder private var sessionConsole: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session", overline: "Record or inspect the current stream")
            if let w = model.activeWorkout {
                activeWorkoutCard(w)
            } else {
                NoopCard {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            sessionPrompt
                            Spacer(minLength: 12)
                            sessionActions
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            sessionPrompt
                            sessionActions
                        }
                    }
                }
                if let last = model.lastWorkout {
                    workoutSavedRow(last)
                }
            }
        }
    }

    private var sessionPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready for a marked effort.")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(activeConnection
                 ? "Start a workout when the stream matters. NOOP records the interval, HR, peak, average and effort from the same live feed."
                 : "Connect the strap first, then mark a workout from the live stream.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionActions: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            // All three routed through the unified button system: a filled primary for the lead
            // action, secondary surfaces for the supporting two — sentence-case, single line, 48pt.
            NoopButton("Start workout", systemImage: "figure.run", kind: .primary) {
                showStartSport = true
            }
            .disabled(!activeConnection)
            .help("Track a workout manually — records heart rate and effort until you end it.")

            NoopButton("Refresh", systemImage: "arrow.clockwise", kind: .secondary) {
                model.getBattery()
            }
            .disabled(!activeConnection)
            .help("Refresh strap battery and connection state.")

            // Manual HRV snapshot (#127) — a still, seated 60s R-R reading. Needs the live R-R
            // stream, so it's gated on a bonded connection just like the workout/refresh actions.
            NoopButton("HRV reading", systemImage: "waveform.path.ecg", kind: .secondary) {
                showHRVSnapshot = true
            }
            .disabled(!activeConnection)
            .help(activeConnection
                  ? "Take a 60-second seated HRV reading from the live R-R stream."
                  : "Connect your strap first — the reading needs the live R-R stream.")
        }
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(StrandPalette.metricRose).frame(width: 8, height: 8)
                    Text("RECORDING WORKOUT").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking).foregroundStyle(StrandPalette.metricRose)
                    Spacer()
                    // Re-render once a second so the elapsed clock ticks without a manual Timer.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsed(since: w.start)).font(StrandFont.number(17)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                HStack(spacing: NoopMetrics.gap) {
                    workoutStat("HR", model.bpm.map { "\($0)" } ?? "—",
                                tint: model.bpm == nil ? StrandPalette.textPrimary : StrandPalette.metricRose)
                    workoutStat("Avg", w.avgHr > 0 ? "\(w.avgHr)" : "—")
                    workoutStat("Peak", w.peakHr > 0 ? "\(w.peakHr)" : "—")
                    workoutStat("Effort", UnitFormatter.effortDisplay(w.liveStrain, scale: effortScale),
                                tint: StrandPalette.strainColor(w.liveStrain))
                }
                HStack(spacing: NoopMetrics.rowSpacing) {
                    // Re-open the full live workout screen (#238) after it's been dismissed.
                    NoopButton("Open live view", systemImage: "rectangle.expand.vertical",
                               kind: .secondary, fullWidth: true) {
                        showLiveWorkout = true
                    }
                    NoopButton("End workout", systemImage: "stop.circle.fill",
                               kind: .destructive, fullWidth: true) {
                        model.endWorkout()
                    }
                }
            }
        }
    }

    private func workoutStat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.number(17))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = ["\(mins) min", row.avgHr.map { "\($0) avg bpm" },
                     row.strain.map { "effort \(UnitFormatter.effortDisplay($0, scale: effortScale))" }].compactMap { $0 }
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
            Text("Workout saved · \(parts.joined(separator: " · "))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func reconnectGuideBanner(_ guide: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can't connect — your strap's pairing was reset")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(guide)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnect help: \(guide)")
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live HR works — free the strap to unlock buzz, alarms & sync")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(hint)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pairing help: \(hint)")
    }

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Calm inline note for the #80 low-bandwidth fallback. Unlike the amber pairing/reconnect banners this
    /// is NOT a warning — live HR is working — so it uses the accent (health-green) treatment with a signal
    /// glyph. Mirrors the banner layout (icon + headline + one-line explanation) for visual consistency.
    private func standardHRNote(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Standard HR mode (low bandwidth)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Other metrics (R-R, frames, battery, history) need a full sync.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.accent.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Standard HR mode, low bandwidth. \(detail)")
    }

    // MARK: - Strap picker

    /// Pick the strap family to scan for. Switching the selection drops the current strap's bond so the
    /// newly-picked one connects fresh — letting a user move between a WHOOP 4 and a 5/MG.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                SegmentedPillControl(
                    WhoopModel.allCases,
                    selection: Binding(
                        get: { selectedModel },
                        set: { newModel in
                            guard newModel.rawValue != selectedModelRaw else { return }
                            selectedModelRaw = newModel.rawValue
                            // Clear the previous strap's sticky bond/connection so the next scan targets the
                            // new family's service and bonds it fresh.
                            model.prepareStrapSwitch()
                        }
                    ),
                    label: { $0.displayName }
                )
                Spacer()
            }
            // Proactive 5/MG guidance: the strap bonds to one host at a time, so if it's still paired in
            // the official WHOOP app a scan here finds nothing. Shown the moment 5/MG is picked — not only
            // after a failed scan (#130) or a bond-refusal (which is the separate `pairingHint` banner).
            if selectedModel == .whoop5mg { whoop5PairingNote }
        }
    }

    private var whoop5PairingNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(StrandPalette.accent)
            Text("WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Offline connect callout

    /// The above-the-fold primary Connect affordance, shown only while `!live.connected`. Promotes the
    /// formerly-inert "Scan and connect…" caption into an accent NoopCard with a real, full-width
    /// `scanButton` (the same one `controls` renders below), so the offline state has an obvious action
    /// up top instead of burying it past the Signal Trust grid. Shared with macOS — the wide layout
    /// shows it stacked above the console, and `scanButton` already styles full-width.
    @ViewBuilder private var offlineConnectCallout: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start a live stream")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        // Name the band Scan will connect to, and point pairing/switching at Devices — so
                        // an offline user knows both what this button does and where to add a different band.
                        Text("Scan connects to \(activeDeviceName). To pair or switch bands, open Devices.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                scanButton
            }
        }
    }

    // MARK: - Manage devices link

    /// A persistent "where to pair / switch bands" row beneath the Scan / Disconnect controls. It sends
    /// the user to the first-class Devices manager and stays one tap away in every connection state,
    /// naming the active band so the link reads in context. The shell routes the request via `NavRouter` —
    /// macOS selects the Devices sidebar item, iOS presents the Devices screen.
    private var manageDevicesRow: some View {
        Button { router.openDevices() } label: {
            HStack(spacing: 12) {
                Image(systemName: "badge.plus.radiowaves.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage devices")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(manageDevicesDetail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(NoopMetrics.space3)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage devices")
        .accessibilityHint("Opens the Devices screen, where you pair and switch bands.")
    }

    /// One-line subtitle for the Manage-devices row — names the active band and reads correctly whether
    /// it's the live link ("Connected to …") or just the band Scan would target ("… is your active band").
    private var manageDevicesDetail: String {
        activeConnection
            ? "Connected to \(activeDeviceName). Pair or switch bands in Devices."
            : "\(activeDeviceName) is your active band. Pair or switch bands in Devices."
    }

    // MARK: - Controls

    private var controls: some View {
        // Three equal thirds can't hold all three labels at a legible size on a phone — the longest
        // ("Scan & Connect") truncates to "Scan &…" even after shrink-to-fit (#175). So on iOS the
        // primary action takes a full-width row and the two secondary actions share the row beneath;
        // macOS keeps the single three-up row, where the window is always wide enough. (#175)
        #if os(iOS)
        VStack(spacing: NoopMetrics.rowSpacing) {
            scanButton
            HStack(spacing: NoopMetrics.rowSpacing) {
                buzzButton
                disconnectButton
            }
        }
        #else
        HStack(spacing: NoopMetrics.rowSpacing) {
            scanButton
            buzzButton
            disconnectButton
        }
        #endif
    }

    // The connect / buzz / disconnect controls, all routed through the unified NOOP button system:
    // a filled primary for the lead Scan action, a secondary surface for Buzz, and the destructive
    // role for Disconnect — sentence-case, single line, optical-centred at controlHeight.
    private var scanButton: some View {
        NoopButton(live.connected ? "Re-scan" : "Scan & connect",
                   systemImage: "antenna.radiowaves.left.and.right",
                   kind: .primary, fullWidth: true) {
            model.scan(model: selectedModel)
        }
    }

    private var buzzButton: some View {
        NoopButton("Buzz strap", systemImage: "waveform.path",
                   kind: .secondary, fullWidth: true) {
            model.buzz()
        }
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var disconnectButton: some View {
        NoopButton("Disconnect", systemImage: "xmark.circle",
                   kind: .destructive, fullWidth: true) {
            model.disconnect()
        }
        .disabled(!live.connected)
    }

    /// Live tab appeared: take a ref-count on the realtime stream (arms it on the 0→1 edge) and pull a
    /// battery reading. Balanced by the single `stopRealtimeHR()` on `.onDisappear`.
    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    /// Honour a one-shot "Return to workout" from the Today indicator card: present the in-exercise screen
    /// for an already-running workout, then clear the flag. The #238 "a workout just started" transition
    /// trigger never fires for a session that is already in flight, so this is the path that re-opens it.
    /// Guarded on a live `activeWorkout` so a stale flag can never present an empty live-workout sheet, and
    /// it sets the SAME `showLiveWorkout` one-shot the manual re-open button uses (no new sheet machinery).
    private func consumeActiveWorkoutRequest() {
        guard router.presentActiveWorkout else { return }
        router.presentActiveWorkout = false
        if model.activeWorkout != nil { showLiveWorkout = true }
    }

    /// A fresh bond/connection landed while the Live tab is up: re-arm the BLE stream (Apple re-sends
    /// startRealtime on a new connection) and refresh battery — WITHOUT taking another ref-count, since
    /// these events can fire several times per appearance against the single `.onDisappear` release.
    private func reconnectLiveSession() {
        guard activeConnection else { return }
        model.rearmRealtimeIfWanted()
        model.getBattery()
    }

    // MARK: - Strap log

    private var logCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    // Export the log so people can attach it to a bug report (issue #17 — macOS users
                    // had no way to share it). Copy → clipboard; Save… → a .txt file.
                    Button("Copy") { copyStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") { saveStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                                Text(line).font(StrandFont.mono)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: 200)
                    .onChangeCompat(of: live.log.count) { _ in
                        if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }

                // Users look on Live first when something's wrong (#507/#509), so link straight into the
                // Test Centre diagnostic home, one tap from the log.
                Divider().overlay(StrandPalette.hairline)
                NavigationLink(destination: TestCentreView()) {
                    HStack(spacing: 8) {
                        Image(systemName: "testtube.2").foregroundStyle(StrandPalette.accent)
                        Text("Open Test Centre to report a bug").font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.accent)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Test Centre")
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    // The strap-log text builder now lives on LiveState (`exportableLogText()`) so the macOS Settings
    // shortcut shares the exact same output (#17 / #507). These stay as thin wrappers.
    private func copyStrapLog() {
        PlatformPasteboard.copy(live.exportableLogText())
    }

    private func saveStrapLog() {
        FileExport.exportText(live.exportableLogText(),
                              suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
    }
}

// MARK: - Signal Trust tile

/// One card in the Signal Trust rail: an icon + ALL-CAPS title, a coloured value, and a one-line
/// detail. The whole card is combined into a single accessibility element so VoiceOver reads
/// "Heart rate: 62 bpm. Streaming now." rather than three disjoint fragments.
private struct SignalTrustTile: View {
    struct Model: Identifiable {
        let title: String
        let value: String
        let detail: String
        let icon: String
        let tint: Color
        var id: String { title }
    }

    let tile: Model

    var body: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: tile.icon)
                        .foregroundStyle(tile.tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(tile.title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(tile.value)
                    .font(StrandFont.headline)
                    .foregroundStyle(tile.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(tile.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 112)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.title): \(tile.value). \(tile.detail)")
    }
}
