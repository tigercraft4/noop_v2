import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false

    /// Opt-in WHOOP 5/MG protocol experiments (off by default). See [PuffinExperiment].
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false

    /// Opt-in WHOOP 5/MG raw-frame capture to a file (off by default). See [PuffinFrameRecorder].
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// Opt-in WHOOP 5/MG "R22" deep-data unlock (off by default) — the one probe that writes a
    /// persistent feature flag to the strap. See [PuffinExperiment.deepDataKey]. (#174)
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    /// Opt-in "Broadcast heart rate" (off by default) — makes the strap advertise its HR as a standard
    /// BLE sensor for Garmin/Zwift/gym kit. See [PuffinExperiment.broadcastHrKey]. (#181)
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHrEnabled = false

    /// Opt-in "Continuous HRV capture" (off by default) — holds the dense realtime stream armed 24/7 so
    /// the strap banks beat-to-beat R-R for better overnight HRV/recovery/sleep, at a battery cost.
    /// See [PuffinExperiment.keepRealtimeForDataKey].
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false

    // Imperial/Metric display preference (D#103). Stored data is always SI; this only changes how
    // distances/weights/heights/temperatures are SHOWN — and lets the profile fields below take
    // imperial entry. Temperature has a separate override so °C/°F can be picked independently.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Effort display scale (#268). Display-only — Effort stays stored 0–100, this only chooses whether
    // it's shown on NOOP's 0–100 axis or WHOOP's 0–21 Day Strain axis.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    // Live-HR Live Activity (Lock Screen + Dynamic Island), iOS only (#336). Default on.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    // Alternate app icon (iOS only) — false = Titanium (primary AppIcon), true = Blue Titanium
    // ("AppIcon-Navy"). Display-only preference; the live switch goes through setAlternateIconName.
    @AppStorage("appIcon.alt") private var useNavyIcon = false
    // Light/Dark/System theme. Read by both app roots' .preferredColorScheme; default follows the OS.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    // Chart colour style: Titanium (brand) or Classic (throwback red→green). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    /// The strap model the user last picked (same key the scan pickers write). Gates the WHOOP 4.0-only
    /// rename control in the strap card — renaming uses the Harvard command set, which a 5/MG doesn't share.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    /// Draft text for the strap-rename field (strap card). Empty placeholder; never pre-seeded so the
    /// current name stays visible separately above it.
    @State private var strapNameDraft = ""

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    /// Raw-sensor CSV export (experimental diagnostic, #308/#276/#322). Holds the last-written file so
    /// macOS can "Reveal in Finder" after a share, mirroring the puffin-capture export.
    @State private var rawCsvBusy = false
    @State private var lastRawCsvURL: URL?

    /// "What's New" changelog sheet, reachable any time from About.
    @State private var showWhatsNew = false

    /// "How your scores work" explainer sheet, reachable any time from About.
    @State private var showScoringGuide = false

    /// Steps-estimate calibration sheet (WHOOP 4.0). Reached from the Profile card's "Steps estimate"
    /// tap-through; explains the estimate, shows the current fit + a recent estimated-vs-phone table,
    /// and offers a manual coefficient override. See [StepsCalibrationSheet].
    @State private var showStepsCalibration = false

    /// iOS environment-diagnostics sheet (device, iOS+build, Data Protection, background refresh,
    /// low-power, sideload + cert expiry). iOS-only; the macOS strap log already carries OS + version.
    @State private var showDiagnostics = false

    /// User-initiated GitHub release check behind the About "Check for updates" button.
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on \(Platform.deviceNounPhrase).") {
            profileCard
            unitsCard
            appearanceCard
            strapCard
            experimentalCard
            backupCard
            aboutCard
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
        .sheet(isPresented: $showScoringGuide) {
            ScoringGuideView(onClose: { showScoringGuide = false })
        }
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: model.repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
        #if os(iOS)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(onClose: { showDiagnostics = false })
        }
        #endif
    }

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Age") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Stepper("Age", value: $profile.age, in: 13...100)
                            .labelsHidden()
                            .accessibilityLabel("Age, \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    // Imperial mode steps in pounds and stores the kg equivalent; metric steps in kg.
                    if unitSystem == .imperial {
                        poundsField(weightKg: $profile.weightKg)
                    } else {
                        measureField(value: $profile.weightKg, unit: "kg",
                                     range: 30...250, step: 0.5, format: "%.1f",
                                     accessibility: "Weight in kilograms")
                    }
                }
                rowDivider
                FormRow(label: "Height") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        feetInchesField(heightCm: $profile.heightCm)
                    } else {
                        measureField(value: $profile.heightCm, unit: "cm",
                                     range: 120...230, step: 1, format: "%.0f",
                                     accessibility: "Height in centimetres")
                    }
                }
                rowDivider
                // Waist (optional). Unlike the rows above it, an empty waist is valid (0 = unset) —
                // it's the ONE measurement that ADDS the VO₂max estimate alongside Fitness Age. It does
                // NOT sharpen the Fitness Age itself (the body term cancels in the Nes model), so it sits
                // apart with an honest "adds your VO₂max estimate" note rather than implying it tunes the age.
                FormRow(label: "Waist (optional)") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        waistInchesField(waistCm: $profile.waistCm)
                    } else {
                        waistCentimetresField(waistCm: $profile.waistCm)
                    }
                }
                Text("Optional — adds your VO₂max estimate. The Fitness Age itself doesn't need it. Measure around your middle, at the navel.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            hrMaxField
                            Text("bpm")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
                rowDivider
                // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor.
                // 1.0 = raw pass-through until the true 5/MG tick rate is known. The divisor goes
                // up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
                // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
                FormRow(label: "Step calibration") {
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f", profile.stepTicksPerStep))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 44, alignment: .trailing)
                        Stepper("Step calibration") {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true)
                        } onDecrement: {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false)
                        }
                            .labelsHidden()
                            .accessibilityLabel("Step calibration, \(String(format: "%.1f", profile.stepTicksPerStep)) counter ticks per step")
                    }
                }
                Text("Counter ticks per step — leave at 1.0 unless your steps run high. On a WHOOP 5/MG they can run very high (10× or more), so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                // Tap-through to the WHOOP 4.0 steps-ESTIMATE calibration (a SEPARATE thing from the
                // 5/MG @57 counter divisor above): a 4.0 sends no step count, so NOOP estimates steps
                // from motion and calibrates that to the phone. The sheet explains it, shows the fit +
                // a recent estimated-vs-phone comparison, and offers a manual coefficient.
                Button {
                    showStepsCalibration = true
                } label: {
                    FormRow(label: "Steps estimate") {
                        HStack(spacing: 8) {
                            Text(stepsCalibrationSummary)
                                .font(StrandFont.footnote)
                                .foregroundStyle(profile.stepsManualCoefficient > 0
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Steps estimate calibration. \(stepsCalibrationSummary). Opens the calibration screen.")
                Text("For a WHOOP 4.0, which sends no step count: NOOP estimates steps from motion, calibrated to your phone. Tap to see how close it is and adjust it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One-line state for the "Steps estimate" tap-through row: manual, the auto-fit confidence, or a
    /// not-yet-calibrated prompt — so the row reflects the current calibration without opening the sheet.
    private var stepsCalibrationSummary: String {
        if profile.stepsManualCoefficient > 0 { return "Manual" }
        if profile.stepsCalibrationCoefficient > 0 {
            return "Auto · \(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) confidence"
        }
        return "Not calibrated"
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
    }

    /// Imperial weight entry: shows pounds, steps in 1-lb increments, and writes the kg equivalent back
    /// to the SI-stored profile. Range mirrors the metric 30…250 kg (≈66…551 lb).
    private func poundsField(weightKg: Binding<Double>) -> some View {
        let lb = Binding<Double>(
            get: { UnitFormatter.kgToPounds(weightKg.wrappedValue) },
            set: { weightKg.wrappedValue = $0 / UnitFormatter.poundsPerKilogram }
        )
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", lb.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text("lb")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper("Weight in pounds", value: lb, in: 66...551, step: 1)
                .labelsHidden()
                .accessibilityLabel("Weight, \(Int(lb.wrappedValue.rounded())) pounds")
        }
    }

    /// Imperial height entry: shows feet′ inches″, steps in whole inches, and writes the cm equivalent
    /// back to the SI-stored profile. Range mirrors the metric 120…230 cm (≈47…91 in).
    private func feetInchesField(heightCm: Binding<Double>) -> some View {
        let inches = Binding<Double>(
            get: { UnitFormatter.cmToInches(heightCm.wrappedValue).rounded() },
            set: { heightCm.wrappedValue = $0 * UnitFormatter.centimetersPerInch }
        )
        let parts = UnitFormatter.cmToFeetInches(heightCm.wrappedValue)
        return HStack(spacing: 10) {
            Text("\(parts.feet)′ \(parts.inches)″")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 56, alignment: .trailing)
            Stepper("Height in inches", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityLabel("Height, \(parts.feet) feet \(parts.inches) inches")
        }
    }

    /// Metric waist entry: 0 = unset (shows a muted "Not set" rather than a misleading 0 cm). Steps in
    /// 1-cm increments; the first increment from unset lands at a sensible 80 cm so the stepper doesn't
    /// crawl up from the range floor. Mirrors `measureField` but tolerant of the optional empty state.
    private func waistCentimetresField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(set ? String(format: "%.0f", waistCm.wrappedValue) : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: 48, alignment: .trailing)
                if set {
                    Text("cm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Stepper("Waist in centimetres") {
                waistCm.wrappedValue = min(160, (set ? waistCm.wrappedValue : 79) + 1)
            } onDecrement: {
                // Stepping below the 60-cm floor clears it back to unset (optional).
                let next = waistCm.wrappedValue - 1
                waistCm.wrappedValue = next < 60 ? 0 : next
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(waistCm.wrappedValue.rounded())) centimetres" : "Waist not set")
        }
    }

    /// Imperial waist entry: 0 = unset (muted "Not set"); otherwise shows whole inches and stores the cm
    /// equivalent — the same metric/imperial treatment as Height. First increment from unset lands near a
    /// sensible 31″. Range mirrors the metric 60…160 cm (≈24…63 in).
    private func waistInchesField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        let inches = set ? UnitFormatter.cmToInches(waistCm.wrappedValue).rounded() : 0
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(set ? "\(Int(inches))" : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: 48, alignment: .trailing)
                if set {
                    Text("in")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Stepper("Waist in inches") {
                let nextIn = (set ? inches : 30) + 1
                waistCm.wrappedValue = min(160, nextIn * UnitFormatter.centimetersPerInch)
            } onDecrement: {
                let nextIn = inches - 1
                // Stepping below the ~24″ floor clears it back to unset (optional).
                waistCm.wrappedValue = nextIn < 24 ? 0 : nextIn * UnitFormatter.centimetersPerInch
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(inches)) inches" : "Waist not set")
        }
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    private var hrMaxField: some View {
        HStack(spacing: 10) {
            Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(profile.hrMaxOverride > 0
                                 ? StrandPalette.textPrimary
                                 : StrandPalette.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
    }

    // MARK: - Units

    /// Imperial/Metric display toggle + a separate temperature override. Display-only — nothing stored
    /// changes, NOOP keeps everything in SI and converts at the point of display.
    private var unitsCard: some View {
        SettingsSection(
            icon: "ruler",
            title: "Units",
            blurb: "Choose how distances, weights, heights, temperatures and Effort are shown. Your data is always stored the same way — this only changes the display."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Measurement system") {
                    Picker("Measurement system", selection: $unitSystemRaw) {
                        Text("Metric").tag(UnitSystem.metric.rawValue)
                        Text("Imperial").tag(UnitSystem.imperial.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Measurement system")
                }
                rowDivider
                FormRow(label: "Temperature") {
                    // Three-way: "Match" follows the system above; °C / °F pin it explicitly. Stored as
                    // an empty string ("match") or the TemperatureUnit raw value.
                    Picker("Temperature", selection: $temperatureRaw) {
                        Text("Match").tag("")
                        Text("°C").tag(TemperatureUnit.celsius.rawValue)
                        Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Temperature unit")
                }
                rowDivider
                // Effort scale (#268) — show NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every Effort read-out.
                FormRow(label: "Effort scale") {
                    Picker("Effort scale", selection: $effortScaleRaw) {
                        Text("0–100").tag(EffortScale.hundred.rawValue)
                        Text("0–21").tag(EffortScale.whoop.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Effort scale")
                }
            }
        }
    }

    // MARK: - Appearance (Theme everywhere; alternate app icon iOS-only)

    /// Theme (System / Light / Dark) on every platform, plus the iOS app-icon choice. The Theme picker
    /// writes `AppearanceMode.storageKey`, which both app roots read via `.preferredColorScheme`; because
    /// every palette token is a dynamic `Color(light:dark:)`, the whole UI re-resolves on change.
    private var appearanceCard: some View {
        SettingsSection(
            icon: "circle.lefthalf.filled",
            title: "Appearance",
            blurb: "Choose Light, Dark, or follow your system. Light keeps NOOP's gold on warm paper; Dark is the signature navy."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Theme") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Theme")
                }
                FormRow(label: "Chart colours") {
                    // Titanium = the brand gold/amber/blue data ramps; Classic = the throwback
                    // red→amber→green readiness scale (cool→hot zones, green→red stress). Both schemes.
                    Picker("Chart colours", selection: $chartStyleRaw) {
                        ForEach(ChartStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Chart colours")
                }
                #if os(iOS)
                FormRow(label: "App icon") {
                    Picker("App icon", selection: $useNavyIcon) {
                        Text("Titanium").tag(false)
                        Text("Blue Titanium").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("App icon")
                    .onChangeCompat(of: useNavyIcon) { applyAppIcon($0) }
                }
                #endif
            }
        }
    }

    #if os(iOS)
    /// Apply the alternate-icon choice. Runs on the main actor (UIKit requirement) and tolerates the
    /// no-op cases (already-set, unsupported); on failure it surfaces the error and reverts the toggle
    /// so the control never disagrees with what's actually on the Home Screen.
    private func applyAppIcon(_ useNavy: Bool) {
        Task { @MainActor in
            let target = useNavy ? "AppIcon-Navy" : nil
            // No-op if iOS already shows the requested icon (avoids a needless system prompt).
            guard UIApplication.shared.supportsAlternateIcons,
                  UIApplication.shared.alternateIconName != target else { return }
            do {
                try await UIApplication.shared.setAlternateIconName(target)
            } catch {
                useNavyIcon = !useNavy
                backupAlertTitle = "Couldn't change the app icon"
                backupAlertMessage = error.localizedDescription
                showBackupAlert = true
            }
        }
    }
    #endif

    // MARK: - Strap

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill("\(strapStatusTitle)", tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        StatePill(live.charging == true
                                  ? "Battery \(Int(pct.rounded()))% · Charging"
                                  : "Battery \(Int(pct.rounded()))%",
                                  tone: batteryTone(pct), showsDot: false)
                    }
                    Spacer(minLength: 0)
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    Button {
                        model.scan()
                    } label: {
                        Label("Re-scan", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.statusCritical)
                    .disabled(!live.connected && !live.bonded)
                }

                Divider().overlay(StrandPalette.hairline)

                // MARK: Continuous HRV capture — keep the dense beat-to-beat (R-R) stream armed 24/7.
                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }
                Text("Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery — your strap streams heart rate continuously while connected.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // MARK: Strap name — rename the WHOOP 4.0's BLE advertising name (Harvard command set).
                if live.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                    Divider().overlay(StrandPalette.hairline)
                    strapNameControl
                }

                #if os(iOS)
                Divider().overlay(StrandPalette.hairline)
                // MARK: Live Activity — show live HR on the Lock Screen + Dynamic Island (#336).
                Toggle(isOn: $liveActivityEnabled) {
                    Text("Live heart rate in Dynamic Island")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Shows your live heart rate on the Lock Screen and in the Dynamic Island while the strap is connected. Turn it off to keep your live HR out of the Dynamic Island. (Any one already showing clears within a moment.)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
    }

    /// Rename the WHOOP 4.0's BLE advertising name. Shows the current name (read back from firmware in
    /// the connect handshake → `LiveState.advertisingName`) and writes a new one via `renameStrap`. The
    /// strap reboots to apply, so the new name lands on the next connect. WHOOP 4.0 only (Harvard).
    @ViewBuilder private var strapNameControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strap name").strandOverline()
            Text("Current: \(live.advertisingName ?? "—")")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 12) {
                TextField("New strap name", text: $strapNameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .disableAutocorrection(true)
                    .accessibilityLabel("New strap name")
                Button {
                    model.ble.renameStrap(strapNameDraft)
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(strapNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status = live.renameStatus {
                Text(status)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Changes the Bluetooth name your WHOOP 4.0 advertises — what you see when pairing. The strap reboots to apply, so the new name appears the next time it connects. WHOOP 4.0 only.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Shares LiveState.connectionStatus* with the sidebar footer (RootView) so the two never drift (#266).
    private var strapStatusTitle: String { live.connectionStatusLabel }

    private var strapTone: StrandTone {
        if live.connectionStatusIsActive { return .positive }
        if live.connectionStatusIsIdle { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected {
            return "Your strap is paired and sending data. Open Live for a real-time heart rate."
        }
        if live.connected, let hint = live.pairingHint { return hint }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Previously paired but not currently connected. Re-scan to reconnect." }
        return "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: - Backup & restore

    // MARK: - Experimental (WHOOP 5 / MG)

    private var experimentalCard: some View {
        SettingsSection(
            icon: "flask.fill",
            title: "Experimental · WHOOP 5 / MG",
            blurb: "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap — WHOOP 4.0 is never affected."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $puffinExperiments) {
                    Text("Try WHOOP 5/MG protocol probes")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // MARK: R22 deep-data unlock — the one probe that writes to the strap.
                Toggle(isOn: $deepDataEnabled) {
                    Text("Unlock WHOOP 5/MG deep data (R22)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("WHOOP 5/MG straps hand a fresh app only live heart rate. The official app switches on the deeper streams (high-rate HR + motion + history) by writing a set of feature flags — a sequence two independent projects have documented. With this on, the button below sends that exact sequence to your strap. Unlike everything else here it does write to the strap, but it's reversible (it only changes which data the strap chooses to emit) and is the same thing the official app does. Experimental: it may do nothing on your firmware. iPhone/Android only — a Mac can't write to a 5/MG.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if deepDataEnabled {
                    Button {
                        model.ble.enableWhoop5DeepData()
                    } label: {
                        Label("Send enable sequence to strap", systemImage: "bolt.badge.automatic")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(!live.encryptedBond || !live.worn)
                    Text(live.encryptedBond ? (live.worn ? "Wear the strap, tap once, then let it sync and share your strap log." : "Put the strap on first — the deep stream is on-wrist only.") : "Needs the full encrypted bond — close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the unlock).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)

                    // Live R22 telemetry (#174): proof of what the strap is doing right now.
                    if live.r22FlagsAccepted > 0 {
                        Label(live.r22FlagsAccepted >= 15
                              ? "Strap accepted all 15 R22 flags"
                              : "Strap accepted \(live.r22FlagsAccepted)/15 R22 flags…",
                              systemImage: live.r22FlagsAccepted >= 15 ? "checkmark.seal.fill" : "ellipsis")
                            .font(StrandFont.caption)
                            .foregroundStyle(live.r22FlagsAccepted >= 15 ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                    }
                    if live.deepPacketsThisSession > 0 {
                        Label("\(live.deepPacketsThisSession) type-0x2F historical-offload frame\(live.deepPacketsThisSession == 1 ? "" : "s") seen outside our sync — these are history (e.g. another app pulling the strap's backlog), not a live R22 stream (#494).",
                              systemImage: "clock.arrow.circlepath")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if live.r22FlagsAccepted >= 15 {
                        Text("Flags accepted, but the enable sequence doesn't start a separate live stream — the deep records arrive as part of the normal history sync (#494).")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }

                Divider().overlay(StrandPalette.hairline)

                // MARK: Broadcast HR — make the strap a standard BLE HR sensor (Garmin/Zwift/gym).
                Toggle(isOn: $broadcastHrEnabled) {
                    Text("Broadcast heart rate (Garmin/ANT)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: broadcastHrEnabled) { on in model.ble.setBroadcastHr(on) }
                Text("Makes your WHOOP 5.0/MG advertise its heart rate as a standard Bluetooth HR sensor, so a Garmin (Edge/watch), Zwift or gym equipment can use it during a workout. Applied on the next connection (and immediately if connected); writes the strap's whoop_live_hr_in_adv_ind_pkt flag. Reversible. iPhone-side only — a Mac can't write to a 5/MG.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $puffinCapture) {
                    Text("Record puffin frames to a file")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Saves every raw 5/MG frame (with a timestamp and the live heart rate) to a JSON file you can share to help map the biometric layout. This only records frames the strap already sent — it never writes to your strap — so it is safe to leave on. Export the file and attach it to a protocol-mapping issue.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if live.puffinCaptureCount > 0 {
                    Text("\(live.puffinCaptureCount) frame\(live.puffinCaptureCount == 1 ? "" : "s") captured this session.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: 12) {
                        Button {
                            exportPuffinCaptures()
                        } label: {
                            Label("Export frames…", systemImage: "square.and.arrow.up")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)

                        #if os(macOS)
                        Button {
                            revealPuffinCaptures()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(StrandPalette.accent)
                        #endif
                        Spacer(minLength: 0)
                    }
                }

                Divider().overlay(StrandPalette.hairline)

                // MARK: Export raw sensor data (CSV) — a read-only diagnostic over the decoded streams
                // NOOP already stores (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events).
                Button {
                    exportRawSensorCSV()
                } label: {
                    if rawCsvBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                        .padding(.horizontal, 6)
                    } else {
                        Label("Export raw sensor data (CSV)", systemImage: "square.and.arrow.up")
                            .padding(.horizontal, 6)
                    }
                }
                .buttonStyle(.bordered)
                .tint(StrandPalette.accent)
                .disabled(rawCsvBusy)

                #if os(macOS)
                if let url = lastRawCsvURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                }
                #endif

                Text("Dumps the last 24 hours of decoded per-sample sensor streams (heart rate, R-R, motion, steps, SpO₂, skin temperature, respiration, events) to a single CSV — all on \(Platform.deviceNounPhrase), nothing uploaded. Share it to help prototype and test sleep, activity and strength algorithms.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Export the last 24h of decoded sensor streams for the connected strap to a CSV, then save (macOS
    /// NSSavePanel) or share (iOS share sheet) — the same pattern as exportPuffinCaptures(). The store
    /// handle and the strap deviceId both come from the app's single "my-whoop" id.
    private func exportRawSensorCSV() {
        rawCsvBusy = true
        Task {
            let since = Date().timeIntervalSince1970 - 24 * 60 * 60
            guard let store = await model.repo.storeHandle() else {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = "Export failed"
                    backupAlertMessage = "Couldn't open the local store."
                    showBackupAlert = true
                }
                return
            }
            do {
                let url = try await store.exportRawCSV(deviceId: model.deviceId, since: since)
                await MainActor.run {
                    rawCsvBusy = false
                    lastRawCsvURL = url
                    #if os(macOS)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = url.lastPathComponent
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    let fm = FileManager.default
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: url, to: dest)
                    } catch {
                        backupAlertTitle = "Export failed"
                        backupAlertMessage = error.localizedDescription
                        showBackupAlert = true
                    }
                    #else
                    FileExport.exportFile(at: url)
                    #endif
                }
            } catch {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = "Export failed"
                    backupAlertMessage = error.localizedDescription
                    showBackupAlert = true
                }
            }
        }
    }

    /// Flush the in-flight capture, then copy it to a user-chosen location (save panel on macOS) or
    /// hand it to the system share sheet (iOS).
    private func exportPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let src = live.puffinCaptureURL else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch {
            backupAlertTitle = "Export failed"
            backupAlertMessage = error.localizedDescription
            showBackupAlert = true
        }
        #else
        FileExport.exportFile(at: src)
        #endif
    }

    #if os(macOS)
    /// Flush, then reveal the capture file in Finder so the user can grab it directly.
    private func revealPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let url = live.puffinCaptureURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces \(Platform.deviceNounPhrase)'s data with a backup."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // Three labelled buttons must share a narrow iPhone row without wrapping mid-word
                // (the labels otherwise broke to one character per line). Equal width + shrink-to-fit
                // keeps each on a single line. On iPhone the SF Symbol icons were the main space-thief
                // (~90pt/button) and there's no room for them in a 3-up row, so we drop to icon-less
                // text there; macOS is wide enough to keep the icons. No trailing Spacer/ProgressView
                // inside this HStack — either would steal a share of the equal-width row. (#188)
                HStack(spacing: 12) {
                    Button {
                        runExport()
                    } label: {
                        backupButtonLabel("Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    Button {
                        runImport()
                    } label: {
                        backupButtonLabel("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    Button {
                        runCsvExport()
                    } label: {
                        backupButtonLabel("Export CSV…", systemImage: "tablecells")
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)
                }

                if backupBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("Importing overwrites everything currently on \(Platform.deviceNounPhrase). Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect. Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Mac, iPhone, or Android — on-device computed rows are marked APPROXIMATE in its Source column; the full backup stays the lossless restore path.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // Equal-width, single-line label for the three Backup buttons. iPhone is too narrow to fit
    // an icon + text three-up, so it goes icon-less there; macOS keeps the SF Symbol. (#188)
    @ViewBuilder
    private func backupButtonLabel(_ title: String, systemImage: String) -> some View {
        #if os(macOS)
        Label(title, systemImage: systemImage)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity).padding(.horizontal, 6)
        #else
        Text(title)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity).padding(.horizontal, 4)
        #endif
    }

    private func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runImport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runImport()
            handleBackup(result)
        }
    }

    private func runCsvExport() {
        backupBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            backupBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                backupAlertTitle = "CSV exported"
                backupAlertMessage = "Saved to \(url.lastPathComponent). The zip re-imports into NOOP (Data Sources → WHOOP Export) on any Mac, iPhone, or Android device."
                showBackupAlert = true
            case .failure(let message):
                backupAlertTitle = "Export problem"
                backupAlertMessage = message
                showBackupAlert = true
            }
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = "Backup exported"
            backupAlertMessage = "Saved to \(url.lastPathComponent). Copy this file to your other \(Platform.deviceNoun) and use Import there to restore everything."
            showBackupAlert = true
        case .imported:
            backupAlertTitle = "Backup imported"
            backupAlertMessage = "Your data has been restored. Quit and reopen NOOP for it to take effect."
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = "Backup problem"
            backupAlertMessage = message
            showBackupAlert = true
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP — all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v\(AppChangelog.currentVersion)", tone: .neutral, showsDot: false)
                    Spacer()
                    Button {
                        showWhatsNew = true
                    } label: {
                        Label("What's new", systemImage: "sparkles").padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                }

                // How your scores work — the honest explainer for Charge / Effort / Rest and the
                // confidence labels. Always reachable here, mirroring the "What's new" affordance.
                Button {
                    showScoringGuide = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How your scores work")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Charge, Effort and Rest — and how they differ from WHOOP.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How your scores work")

                #if os(iOS)
                // iOS reality & diagnostics — honest expectations for a sideloaded iPhone build, plus a
                // one-tap environment dump (device, iOS+build, Data Protection, background refresh,
                // low-power, sideload expiry) for bug reports. iOS-only; macOS doesn't have these gotchas.
                iosDiagnosticsRow
                iphoneExpectations
                #endif

                // Check for updates — a single, user-initiated read of GitHub's public releases API.
                // No background polling, no auto-update; sends nothing about you, just reads the version.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button {
                            updateChecker.check(currentVersion: AppChangelog.currentVersion)
                        } label: {
                            if updateChecker.state == .checking {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Checking…")
                                }
                            } else {
                                Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                                    .padding(.horizontal, 4)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(updateChecker.state == .checking)

                        if case .upToDate(let v) = updateChecker.state {
                            Text("You're on the latest (\(v)).")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        } else if case .failed = updateChecker.state {
                            Text("Couldn't check. Try again.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                        Spacer()
                    }

                    // Update available: show what's new, with a download straight to the release.
                    if case .available(let v, let url, let notes) = updateChecker.state {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Version \(v) is available")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Button {
                                    openURL(url)
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle.fill")
                                        .padding(.horizontal, 4)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(StrandPalette.accent)
                            }
                            if !notes.isEmpty {
                                ScrollView {
                                    Text(notes)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 150)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(StrandPalette.accent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    Text("Checks GitHub for the latest version when you tap — nothing else is sent.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                Text("A standalone companion for your WHOOP. Everything stays on this device — your history, your live stream, your numbers. Nothing is uploaded. NOOP is an independent, experimental project, not the WHOOP app.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                    attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - iOS reality & diagnostics (iOS-only)

    #if os(iOS)
    /// A tappable row (mirroring "How your scores work") that opens the environment-diagnostics sheet.
    private var iosDiagnosticsRow: some View {
        Button {
            showDiagnostics = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Diagnostics")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Device, iOS build, Data Protection and sideload status — for bug reports.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Diagnostics")
    }

    /// Calm, honest "what to expect running NOOP on iPhone" callout — sideloading reality, re-sign
    /// cadence, the unlock-after-reboot (#222) note, background-BLE limits, and beta-iOS caveat. Surfaces
    /// the live sideload-cert expiry when we can read it, with a gentle warning under ~3 days.
    private var iphoneExpectations: some View {
        let diag = IOSDiagnostics.capture()
        let expiry = diag.expiryDaysRemaining()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                Text("Using NOOP on iPhone")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }

            iphoneExpectationLine("This is a sideloaded build — installed outside the App Store. It needs re-signing periodically: roughly every 7 days on a free Apple ID, about a year on a paid developer account.")
            iphoneExpectationLine("After your iPhone reboots, unlock it once. Until you do, iOS keeps NOOP's files locked (Data Protection), so new history can't be written or synced.")
            iphoneExpectationLine("Background Bluetooth has OS limits — iOS may pause NOOP when it's not in the foreground, so keep it open while syncing a fresh strap.")
            iphoneExpectationLine("On a beta version of iOS, things can break that work on the release build.")

            if let days = expiry {
                let warning = days <= 3
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text(expiryMessage(days))
                        .font(StrandFont.footnote)
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
        )
    }

    private func expiryMessage(_ days: Int) -> String {
        if days < 0 {
            return "This sideloaded build expired \(-days) day\(abs(days) == 1 ? "" : "s") ago — re-sign it to keep it running."
        }
        return "This sideloaded build expires in \(days) day\(days == 1 ? "" : "s") — re-sign to keep it running."
    }

    private func iphoneExpectationLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Section card

/// A grouped settings card: a "Settings" overline + icon + title header, an explanatory blurb,
/// then content. A faint brand-green wash anchors the card to NOOP's neutral chrome.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - iOS diagnostics sheet

#if os(iOS)
/// A read-only environment dump for bug reports: device, iOS+build, Data Protection (#222),
/// background refresh, low-power, sideload + cert expiry — with a one-tap Copy.
private struct DiagnosticsSheet: View {
    let onClose: () -> Void

    /// Captured once at presentation; a snapshot, not a live monitor.
    private let lines: [String] = IOSDiagnostics.capture().summaryLines()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics").font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Attach this to a bug report.").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(20)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text("No iOS diagnostics available.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(StrandFont.mono(12))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(20)
            }

            Divider().overlay(StrandPalette.hairline)

            HStack {
                Spacer()
                Button {
                    // UIPasteboard via the shared cross-platform wrapper.
                    PlatformPasteboard.copy(lines.joined(separator: "\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(minWidth: 120).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(lines.isEmpty)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
    }
}
#endif

// MARK: - Steps estimate calibration

/// Small shared formatters for the steps-estimate calibration UI — kept apart from the sheet so the
/// Profile-card summary row and the sheet agree on the confidence wording. Mirrors the Android
/// `StepsCalibrationFormat` object.
enum StepsCalibrationFormat {
    /// A 0–1 confidence as Low / Medium / High — the honest read-out the sheet and the summary row share.
    /// Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual coefficient is confidence 1.0 → "High".
    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.34: return "Low"
        case ..<0.67: return "Medium"
        default:      return "High"
        }
    }
}

/// One recent day's estimated-vs-phone steps comparison row, for the sheet's accuracy table.
private struct StepsComparisonRow: Identifiable {
    let day: String          // yyyy-MM-dd
    let estimated: Int
    let actual: Int
    var id: String { day }
    /// Signed error of the estimate against the phone count, as a percentage (estimate − actual) / actual.
    var errorPct: Double { actual > 0 ? Double(estimated - actual) / Double(actual) * 100 : 0 }
}

/// WHOOP 4.0 steps-ESTIMATE calibration — honest explainer + current fit + a recent estimated-vs-phone
/// table + a manual coefficient override with a live preview. Presented as a sheet from Settings →
/// Profile → "Steps estimate". Reads the SAME data the engine fits against (the computed `steps_est`
/// series and the phone's `steps`), never recomputing the headline. Mirrors Android `StepsCalibrationScreen`.
private struct StepsCalibrationSheet: View {
    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Recent days that have BOTH an estimate and a real phone step count, newest first — the accuracy table.
    @State private var comparison: [StepsComparisonRow] = []
    /// A representative recent motion volume (median of recent days' motion), used so the manual-coefficient
    /// preview reflects a TYPICAL day. nil until loaded / no recent estimated day with a known motion.
    @State private var sampleMotion: Double?

    /// The draft manual coefficient the slider edits, committed to ProfileStore on release. 0 = auto-fit.
    @State private var draftManual: Double = 0
    @State private var didLoad = false

    /// The coefficient the slider's max anchors to — generous headroom over whatever the auto-fit found so
    /// a manual nudge in either direction is reachable. Floor keeps the slider usable before any fit.
    private var sliderMax: Double {
        max(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50) * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    explainerCard
                    currentFitCard
                    comparisonCard
                    manualAdjustCard
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await loadIfNeeded() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STEPS ESTIMATE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Calibrate your steps").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("WHOOP 4.0 · motion → steps").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Cards

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How this works", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter — a WHOOP 4.0 doesn't transmit steps.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, NOOP learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence —
    /// or, if nothing's fit yet and no manual value is set, an honest "what we still need" prompt.
    private var currentFitCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current calibration").strandOverline()
                if profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0 {
                    let coeff = profile.stepsManualCoefficient > 0
                        ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1f", coeff))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.accent)
                        Text("steps per motion unit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if profile.stepsManualCoefficient > 0 {
                        statLine("Source", "Manual — you set this by hand")
                    } else {
                        statLine("Fitted from", "\(profile.stepsCalibrationSampleDays) day\(profile.stepsCalibrationSampleDays == 1 ? "" : "s") your phone also counted")
                        statLine("Confidence", "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
                    }
                } else {
                    Text("Not calibrated yet")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("We need a few days where your phone also counted steps (at least \(StepsEstimateEngine.minCalibrationDays)), or set it manually below.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated vs your phone").strandOverline()
                if comparison.isEmpty {
                    Text("No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Column header.
                    HStack {
                        Text("Day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Est.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Phone").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Δ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    ForEach(comparison) { row in
                        HStack {
                            Text(Self.shortDay(row.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.estimated))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.actual))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%+.0f%%", row.errorPct))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(abs(row.errorPct) <= 15
                                                 ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
                    }
                    Text("These days are excluded from the estimate (your phone's real count is shown instead) — they're here only so you can judge the estimate's accuracy.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    private var manualAdjustCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust manually").strandOverline()
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? String(format: "%.1f", draftManual) : "Auto")
                        .font(StrandFont.number(24))
                        .foregroundStyle(draftManual > 0 ? StrandPalette.accent : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.accent)
                .accessibilityValue(draftManual > 0
                                    ? "\(String(format: "%.1f", draftManual)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine("A typical recent day",
                                 "≈ \(Self.grouped(preview)) steps\(draftManual > 0 ? " at this setting" : " (auto)")")
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit + preview cards.
    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Data

    /// Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    /// strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone count
    /// never co-exist in storage. To still SHOW "how close the estimate is", we reconstruct what the
    /// estimate WOULD have been on recent phone-covered days: read each day's motion volume the same way
    /// the engine does (gravity over [localMidnight, +24h)) and run the public `StepsEstimateEngine` with
    /// the live calibration. This reuses the engine, never invents a number, and needs no extra storage.
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        draftManual = profile.stepsManualCoefficient

        // Effective calibration in force right now: a manual override wins, else the persisted auto-fit.
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient

        // Phone reference steps from Apple Health daily rows (steps > 0 only), newest first.
        let appleRows = await repo.appleDailyRows()
        let phoneDays = appleRows
            .compactMap { row -> (day: String, steps: Int)? in
                guard let s = row.steps, s > 0 else { return nil }
                return (row.day, s)
            }
            .sorted { $0.day > $1.day }

        // Reconstruct the estimate for the most recent phone-covered days, motion-by-motion.
        guard coeff > 0, let store = await repo.storeHandle() else { return }
        let cal = StepsEstimateEngine.Calibration(coefficient: coeff,
                                                  sampleDays: profile.stepsCalibrationSampleDays,
                                                  confidence: profile.stepsCalibrationConfidence,
                                                  manual: profile.stepsManualCoefficient > 0)
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var rows: [StepsComparisonRow] = []
        var motions: [Double] = []
        for entry in phoneDays.prefix(10) {           // scan a few extra to fill 7 after motion gaps
            guard let dayDate = dayParser.date(from: entry.day) else { continue }
            let mid = Int(calendar.startOfDay(for: dayDate).timeIntervalSince1970)
            let grav = (try? await store.gravitySamples(deviceId: repo.deviceId, from: mid,
                                                        to: mid + 86_400 - 1, limit: 200_000)) ?? []
            let motion = StepsEstimateEngine.dayMotionIntensity(grav)
            guard motion > 0, let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            motions.append(motion)
            rows.append(StepsComparisonRow(day: entry.day, estimated: est, actual: entry.steps))
            if rows.count >= 7 { break }
        }
        comparison = rows

        // Typical recent day's motion for the live preview = median of the motions we just measured.
        if !motions.isEmpty {
            let s = motions.sorted()
            sampleMotion = s[s.count / 2]
        }
    }

    // MARK: Formatting

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    private static func shortDay(_ key: String) -> String {
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: key) else { return key }
        let outF = DateFormatter(); outF.dateFormat = "EEE d MMM"
        return outF.string(from: d)
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        // iPhone-width (402pt) so the narrow Backup row stays in the preview's blast radius —
        // at 720 the three-up button row had slack and the truncation regression slipped through. (#188)
        .frame(width: 402, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
