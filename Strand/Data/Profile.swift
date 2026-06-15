import Foundation
import Combine

/// User profile (age/sex/body metrics/HR-max) persisted in UserDefaults.
/// Powers HR zones, calories and recovery baselines.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var age: Int { didSet { d.set(age, forKey: K.age) } }
    @Published var sex: String { didSet { d.set(sex, forKey: K.sex) } }          // "male" | "female" | "nonbinary"
    @Published var weightKg: Double { didSet { d.set(weightKg, forKey: K.weight) } }
    @Published var heightCm: Double { didSet { d.set(heightCm, forKey: K.height) } }
    /// Optional waist circumference (cm); 0 = not set. Only used to ALSO show an estimated VO₂max
    /// alongside Fitness Age — the Fitness Age itself does not need it (the body term cancels).
    @Published var waistCm: Double { didSet { d.set(waistCm, forKey: K.waist) } }
    /// 0 = auto-estimate from age.
    @Published var hrMaxOverride: Int { didSet { d.set(hrMaxOverride, forKey: K.hrMax) } }
    /// Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
    /// counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
    /// (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
    @Published var stepTicksPerStep: Double {
        didSet { d.set(min(max(stepTicksPerStep, 0.5), 30.0), forKey: K.stepScale) }
    }

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Written by IntelligenceEngine each analytics pass from the auto-fit against phone steps, and
    // read by the Settings/Steps screen to display + adjust the calibration. `stepsManualCoefficient`
    // is the ONLY user-settable field (0 = auto-fit; > 0 = manual override fed into calibrate()); the
    // other three are fitted outputs, surfaced read-only.
    /// Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine.
    @Published var stepsCalibrationCoefficient: Double { didSet { d.set(stepsCalibrationCoefficient, forKey: K.stepsCoeff) } }
    /// How many calibration days fed the last auto-fit (0 when purely manual / not yet fit).
    @Published var stepsCalibrationSampleDays: Int { didSet { d.set(stepsCalibrationSampleDays, forKey: K.stepsSampleDays) } }
    /// 0–1 trust in the last fit (1.0 for a manual coefficient).
    @Published var stepsCalibrationConfidence: Double { didSet { d.set(stepsCalibrationConfidence, forKey: K.stepsConfidence) } }
    /// True when the persisted coefficient came from the user's manual override, not an auto-fit.
    @Published var stepsCalibrationManual: Bool { didSet { d.set(stepsCalibrationManual, forKey: K.stepsManualFlag) } }
    /// User-set manual coefficient. 0 = auto-fit (nil to the engine); > 0 = manual override.
    @Published var stepsManualCoefficient: Double { didSet { d.set(max(0, stepsManualCoefficient), forKey: K.stepsManualCoeff) } }

    private let d = UserDefaults.standard
    private enum K {
        static let age = "profile.age", sex = "profile.sex", weight = "profile.weightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride"
        static let stepScale = "profile.stepTicksPerStep"
        static let waist = "profile.waistCm"
        static let stepsCoeff = "profile.stepsCalibrationCoefficient"
        static let stepsSampleDays = "profile.stepsCalibrationSampleDays"
        static let stepsConfidence = "profile.stepsCalibrationConfidence"
        static let stepsManualFlag = "profile.stepsCalibrationManual"
        static let stepsManualCoeff = "profile.stepsManualCoefficient"
    }

    init() {
        age = d.object(forKey: K.age) as? Int ?? 30
        sex = d.string(forKey: K.sex) ?? "male"
        weightKg = d.object(forKey: K.weight) as? Double ?? 75
        heightCm = d.object(forKey: K.height) as? Double ?? 178
        waistCm = d.object(forKey: K.waist) as? Double ?? 0
        hrMaxOverride = d.object(forKey: K.hrMax) as? Int ?? 0
        stepTicksPerStep = min(max(d.object(forKey: K.stepScale) as? Double ?? 1.0, 0.5), 30.0)
        stepsCalibrationCoefficient = d.object(forKey: K.stepsCoeff) as? Double ?? 0
        stepsCalibrationSampleDays = d.object(forKey: K.stepsSampleDays) as? Int ?? 0
        stepsCalibrationConfidence = d.object(forKey: K.stepsConfidence) as? Double ?? 0
        stepsCalibrationManual = d.object(forKey: K.stepsManualFlag) as? Bool ?? false
        stepsManualCoefficient = max(0, d.object(forKey: K.stepsManualCoeff) as? Double ?? 0)
    }

    /// The manual override to feed into `StepsEstimateEngine.calibrate(_:manualOverride:)`:
    /// nil when 0 (auto-fit), the positive value otherwise.
    var stepsManualOverride: Double? { stepsManualCoefficient > 0 ? stepsManualCoefficient : nil }

    /// Tanaka estimate unless overridden.
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded()) }

    /// Allowed range for the step-calibration divisor (#132). 5/MG straps overcount by
    /// up to ~24×, so the old 4.0 ceiling could never reach the truth.
    static let stepScaleRange: ClosedRange<Double> = 0.5...30.0

    /// Variable step for the calibration stepper so high values stay reachable: fine near
    /// the 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat
    /// 0.1 step from 0.5 to 30 would be ~295 taps — unusable.
    /// - `< 2.0` → 0.1   (precision around the default)
    /// - `2.0–5.0` → 0.5
    /// - `≥ 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
    static func stepScaleIncrement(for value: Double) -> Double {
        switch value {
        case ..<2.0: return 0.1
        case ..<5.0: return 0.5
        default: return 1.0
        }
    }

    /// One increment/decrement of the calibration divisor, snapped to the increment grid and
    /// clamped to ``stepScaleRange``. Decrement uses the increment for the *target* band so the
    /// up/down sequence is symmetric at the band boundaries (e.g. 5.0 −1 → 4.0, 4.0 +0.5 → 4.5).
    static func steppedStepScale(_ value: Double, up: Bool) -> Double {
        let delta = up ? stepScaleIncrement(for: value)
                       : stepScaleIncrement(for: value - 0.0001)
        let next = ((value + (up ? delta : -delta)) / delta).rounded() * delta
        return min(max(next, stepScaleRange.lowerBound), stepScaleRange.upperBound)
    }
}
