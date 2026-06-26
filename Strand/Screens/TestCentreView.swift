import SwiftUI
import StrandDesign
import StrandAnalytics

/// Settings -> Test Centre. The single home for every diagnostic, log and test control (spec section 7).
///
/// Four sections: domain test modes (rendered from the registry projection), diagnostic tools, export
/// and auto-export, advanced/experimental. Section 1 iterates TestCentreLayout.visibleModes so adding a
/// profile later is a registry entry, never a new screen. The lower three sections re-host the same
/// bindings and actions that live in SettingsView (strap log, recalibrate, scheduled export, the 5/MG
/// experimental toggles) so the Test Centre is the one place to find them; SettingsView keeps a thin nav
/// link in. No em-dash in any string here.
struct TestCentreView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    /// The Report orchestrator: assembles the redacted bundle, runs the mandatory review gate, shares.
    @StateObject private var report = TestCentreReport()

    /// Re-read activation on appear so a toggle flip elsewhere reflects here.
    @State private var refreshToken = 0

    // Section 2: recalibrate confirm.
    @State private var showRecalibrateConfirm = false
    @State private var infoTitle = ""
    @State private var infoMessage = ""
    @State private var showInfo = false

    // Section 3: scheduled daily auto-export, the same ScheduledDebugExport store the Settings card uses.
    @State private var debugExportOn = ScheduledDebugExport.isEnabled
    @State private var debugExportMinutes = ScheduledDebugExport.timeMinutes

    // Section 4: the experimental toggles, on the SAME @AppStorage keys as SettingsView (preserved per
    // spec section 10), so toggling here and there is one and the same setting.
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var experimentalSleepV2Enabled = false
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHrEnabled = false
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// The strap model the user last picked, the same key SettingsView's showFiveMGControls gate reads.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue

    /// True when the connected strap is a 5/MG, so the 5/MG experimental block shows. Mirrors the
    /// SettingsView gate (#22): a confident 4.0 owner never sees controls that cannot touch their strap.
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The "whole app" report profile for the section-3 manual Report button. master is not a registry
    /// mode (it has no wear-and-capture flow), so the deep-link self-applies the test:all label via this.
    static let masterReportMode = TestMode(
        domain: .master, title: "Bug report", blurb: "", icon: "ladybug", priority: .high,
        captures: [], questionnaire: [], liveReadout: [],
        capture: .toggle, includesScreenshot: false, requires5MG: false)

    var body: some View {
        ScreenScaffold(title: "Test Centre",
                       subtitle: "Turn on a test for the thing that's wrong, wear the strap, then tap Report. All on \(Platform.deviceNounPhrase).") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                domainModesCard.staggeredAppear(index: 0)
                diagnosticToolsCard.staggeredAppear(index: 1)
                exportCard.staggeredAppear(index: 2)
                advancedCard.staggeredAppear(index: 3)
            }
        }
        .id(refreshToken)
        .onAppear {
            refreshToken &+= 1
            ScheduledDebugExport.activateIfEnabled()
        }
        .sheet(item: $report.pending) { _ in
            ReportReviewSheet(report: report)
        }
        .confirmationDialog("Recalibrate your Charge baseline?",
                            isPresented: $showRecalibrateConfirm, titleVisibility: .visible) {
            Button("Recalibrate") { recalibrateCharge() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays.")
        }
        .alert(infoTitle, isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(infoMessage)
        }
    }

    // MARK: - Section 1: Domain test modes (rendered from the registry projection)

    @ViewBuilder private var domainModesCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("TEST MODES")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Each test logs extra detail for one part of the app while you wear the strap, then bundles it for a bug report.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                let modes = TestCentreLayout.visibleModes(is5MG: is5MG)
                ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
                    if idx > 0 { Divider().overlay(StrandPalette.hairline) }
                    TestModeRow(mode: mode, report: report)
                }
            }
        }
    }

    // MARK: - Section 2: Diagnostic tools (strap log + recalibrate + env dump)

    @ViewBuilder private var diagnosticToolsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("DIAGNOSTIC TOOLS")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                // Strap log, the same exportableLogText the Settings + Live strap-log cards share.
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { PlatformPasteboard.copy(live.exportableLogText()) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") {
                        FileExport.exportText(live.exportableLogText(),
                                              suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
                    }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                Text("Grab this when you report a bug. It tells me what the app saw.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // Recalibrate Charge baseline: the same Baselines.recalibrateRecoveryBaselines call the
                // Settings Recovery card uses.
                NoopButton("Recalibrate Charge baseline", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                    showRecalibrateConfirm = true
                }
                Text("Re-anchors every baseline that feeds Charge to your recent nights. No stored day is deleted.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // Environment dump: the IOSDiagnostics-backed block exportableLogText already carries,
                // surfaced as a copyable readout (spec section 3.4).
                NoopButton("Copy environment dump", systemImage: "info.circle", kind: .secondary) {
                    PlatformPasteboard.copy(live.exportableLogText())
                }
            }
        }
    }

    // MARK: - Section 3: Export and auto-export (manual Report + scheduled export)

    @ViewBuilder private var exportCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("EXPORT")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                NoopButton("Report a bug with my log", systemImage: "paperplane", kind: .primary) {
                    // A generic "whole app" report: the master profile so the deep-link self-applies the
                    // test:all label. master is not in the registry (it is not a wear-and-capture mode), so
                    // build the lightweight mode inline.
                    report.start(mode: TestCentreView.masterReportMode, live: live)
                }
                Text("Builds a redacted .zip, shows you exactly what it contains, then opens a prefilled GitHub issue. You attach the file on the next screen.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = report.lastStatus {
                    Text(status)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                // Scheduled daily auto-export, the same ScheduledDebugExport reads/writes as the Settings
                // Diagnostics card. iOS BGAppRefresh is best-effort, the honest caption is kept.
                Toggle(isOn: $debugExportOn) {
                    Text("Daily auto-export of the strap log")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                .onChangeCompat(of: debugExportOn) { on in ScheduledDebugExport.setEnabled(on) }

                if debugExportOn {
                    HStack {
                        Text("Time of day").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: debugExportTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Daily auto-export time")
                    }
                    NoopButton("Run now", systemImage: "square.and.arrow.down.on.square", kind: .secondary) {
                        runScheduledExportNow()
                    }
                    Text("On iPhone this is best-effort (iOS decides when background tasks run). Everything stays on \(Platform.deviceNounPhrase).")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Section 4: Advanced / experimental

    @ViewBuilder private var advancedCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("ADVANCED")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                // Model-agnostic advanced toggles (shown on every strap), same @AppStorage keys as Settings.
                Toggle(isOn: $experimentalSleepV2Enabled) {
                    Text("Experimental sleep staging (V2)")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)

                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }

                // 5/MG-only probes, hidden off a 4.0 strap (the #22 gate, same as SettingsView).
                if is5MG {
                    Divider().overlay(StrandPalette.hairline)
                    Text("WHOOP 5 / MG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Toggle(isOn: $puffinExperiments) {
                        Text("Try WHOOP 5/MG protocol probes")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)

                    Toggle(isOn: $deepDataEnabled) {
                        Text("Unlock WHOOP 5/MG deep data (R22)")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)

                    Toggle(isOn: $broadcastHrEnabled) {
                        Text("Broadcast heart rate (Garmin/ANT)")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)
                    .onChangeCompat(of: broadcastHrEnabled) { on in model.ble.setBroadcastHr(on) }

                    Toggle(isOn: $puffinCapture) {
                        Text("Record puffin frames to a file")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)
                }

                Text("These are experimental probes, off by default. The fuller WHOOP 5/MG controls and the raw-sensor CSV export still live in Settings under Diagnostics.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared actions (same calls as the SettingsView controls these re-host)

    /// Re-anchor every baseline that feeds Charge from now, via the single cross-platform source of
    /// truth, then kick a recompute. Same path as the Settings Recovery card.
    private func recalibrateCharge() {
        Baselines.recalibrateRecoveryBaselines()
        Task {
            await model.intelligence.analyzeRecent()
            await model.repo.refresh()
        }
        infoTitle = "Charge baseline recalibrating"
        infoMessage = "NOOP will re-learn your baseline from tonight's data onward. Your history is kept, and it takes a few nights to settle."
        showInfo = true
    }

    private var debugExportTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = debugExportMinutes / 60
                c.minute = debugExportMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                debugExportMinutes = m
                ScheduledDebugExport.setTimeMinutes(m)
            }
        )
    }

    private func runScheduledExportNow() {
        model.ble.flushPuffinCaptures()
        let url = ScheduledDebugExport.runNow(captureURL: live.puffinCaptureURL)
        if let url {
            infoTitle = "Strap log exported"
            #if os(iOS)
            infoMessage = "Saved \(url.lastPathComponent) to NOOP's folder in the Files app."
            #else
            infoMessage = "Saved \(url.lastPathComponent) to your Documents folder."
            #endif
        } else {
            infoTitle = "Export failed"
            infoMessage = "Couldn't write the strap log right now."
        }
        showInfo = true
    }
}

/// One domain-test-mode row: icon + title + status + blurb, a toggle wired to TestCentre, and a Report
/// action. Toggling calls TestCentre.activate/deactivate (the single prefs namespace).
private struct TestModeRow: View {
    let mode: TestMode
    @ObservedObject var report: TestCentreReport
    @EnvironmentObject var live: LiveState
    @State private var on: Bool = false

    private var elapsed: Double? {
        TestCentre.startedAt(mode.domain).map { Date().timeIntervalSince($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .foregroundStyle(StrandPalette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Text(TestCentreLayout.statusText(for: mode, active: on, elapsedSeconds: elapsed))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $on)
                    .labelsHidden()
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("\(mode.title) test mode")
                    .onChangeCompat(of: on) { isOn in
                        if isOn { TestCentre.activate(mode.domain) } else { TestCentre.deactivate(mode.domain) }
                    }
            }
            Text(mode.blurb)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Report") { report.start(mode: mode, live: live) }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Report a \(mode.title) bug")
            }
        }
        .onAppear { on = TestCentre.active(mode.domain) }
    }
}

/// The mandatory review-before-share sheet (spec sections 9 and 12): shows the exact redacted report.txt
/// the user is about to share, with explicit Share and Cancel. Nothing leaves the device until Share.
private struct ReportReviewSheet: View {
    @ObservedObject var report: TestCentreReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preview = report.pending?.gate.previewText ?? ""
        return ScreenScaffold(title: "Review before sharing",
                              subtitle: "This is exactly what your report will contain. Nothing leaves \(Platform.deviceNounPhrase) until you tap Share.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                NoopCard {
                    ScrollView {
                        Text(preview.isEmpty ? "(nothing to share yet)" : preview)
                            .font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 360)
                }
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Cancel", systemImage: "xmark", kind: .secondary) {
                        report.cancel(); dismiss()
                    }
                    NoopButton("Share", systemImage: "square.and.arrow.up", kind: .primary) {
                        report.confirm(); dismiss()
                    }
                }
            }
        }
    }
}
