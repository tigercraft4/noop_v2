package com.noop.analytics

import com.noop.data.GravitySample
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Estimate daily steps for a WHOOP 4.0 from the strap's MOTION, calibrated per-user against a phone
 * step count (Apple Health / Health Connect). Byte-for-byte twin of the Swift StepsEstimateEngine.
 *
 * WHY A CALIBRATED ESTIMATE, NOT A PEDOMETER. A WHOOP 4.0 does not send a step count over BLE, and the
 * gravity data we DO get is sparse (~one vector per stored record, ~minute granularity) — far below the
 * ~25–50 Hz a true step counter needs to see footfalls. So we cannot count steps. We CAN measure movement
 * VOLUME (how much the gravity vector moved over the day) and map it to steps with a coefficient learned
 * from days where the phone ALSO counted steps. The output is always framed as an estimate.
 *
 * THE MODEL. `steps ≈ k · motionIntensity`, through-origin. `k` (steps per unit of motion) is the only free
 * parameter and is PERSONAL (wrist placement, gait, how the strap rides) — hence calibrated per user, not a
 * global constant. We fit `k` robustly (median of per-day steps/motion ratios) so one odd day can't drag it.
 * A user with no phone step history can set `k` by hand with the calibration slider.
 */
object StepsEstimateEngine {

    /** Fewest calibration days (each with both motion and a reference step count) before we trust an auto-fit `k`. */
    const val MIN_CALIBRATION_DAYS = 3
    /** Calibration days at/above which confidence saturates toward 1. */
    const val GOOD_CALIBRATION_DAYS = 14
    /** A day must move at least this much (summed gravity-delta) to enter the fit / produce an estimate. */
    const val MIN_MOTION_FOR_FIT = 1.0
    /** Sanity clamp on a daily estimate. */
    const val MAX_DAILY_STEPS = 60_000

    /** One calibration day: the strap's motion volume and the phone's step count for the SAME day. */
    data class CalibrationPoint(val motion: Double, val steps: Double)

    /** The fitted (or manually-set) personal model. */
    data class Calibration(
        val coefficient: Double,
        val sampleDays: Int,
        val confidence: Double,
        val manual: Boolean,
    )

    /**
     * Total daily MOTION INTENSITY = sum of per-record gravity-vector deltas (L2 magnitude of the change
     * between consecutive samples). Movement VOLUME over the day — the same proxy the sleep stager uses for
     * stillness, integrated. (Mirror of Swift dayMotionIntensity.)
     */
    fun dayMotionIntensity(grav: List<GravitySample>): Double {
        if (grav.size < 2) return 0.0
        var total = 0.0
        var prev = grav[0]
        for (i in 1 until grav.size) {
            val r = grav[i]
            val dx = prev.x - r.x; val dy = prev.y - r.y; val dz = prev.z - r.z
            total += sqrt(dx * dx + dy * dy + dz * dz)
            prev = r
        }
        return total
    }

    /**
     * Fit the personal coefficient from days that have BOTH a motion volume and a reference step count.
     * Robust: median of each day's steps/motion ratio (days below MIN_MOTION_FOR_FIT skipped). Returns null
     * below MIN_CALIBRATION_DAYS unless a positive [manualOverride] is supplied (which always wins, confidence 1).
     */
    fun calibrate(points: List<CalibrationPoint>, manualOverride: Double? = null): Calibration? {
        if (manualOverride != null && manualOverride > 0) {
            return Calibration(manualOverride, points.size, 1.0, manual = true)
        }
        val ratios = points
            .filter { it.motion >= MIN_MOTION_FOR_FIT && it.steps > 0 }
            .map { it.steps / it.motion }
            .sorted()
        if (ratios.size < MIN_CALIBRATION_DAYS) return null
        val k = median(ratios)
        if (k <= 0) return null
        val sizeTerm = min(1.0, ratios.size.toDouble() / GOOD_CALIBRATION_DAYS)
        val mad = median(ratios.map { abs(it - k) })
        val spread = if (k > 0) mad / k else 1.0
        val tightness = (1.0 - spread).coerceAtLeast(0.0)
        val confidence = (0.5 * sizeTerm + 0.5 * tightness).coerceIn(0.0, 1.0)
        return Calibration(k, ratios.size, confidence, manual = false)
    }

    /**
     * Estimated steps for a day from its motion volume and the personal calibration. null below
     * MIN_MOTION_FOR_FIT (too little to say) — the UI then shows "—", never a fake 0.
     */
    fun estimate(motion: Double, calibration: Calibration): Int? {
        if (motion < MIN_MOTION_FOR_FIT || calibration.coefficient <= 0) return null
        return Math.round(motion * calibration.coefficient).toInt().coerceIn(0, MAX_DAILY_STEPS)
    }

    internal fun median(xs: List<Double>): Double {
        if (xs.isEmpty()) return 0.0
        val s = xs.sorted(); val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
