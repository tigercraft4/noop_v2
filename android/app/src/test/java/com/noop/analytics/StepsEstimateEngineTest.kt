package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift StepsEstimateEngineTests — same numbers, same expectations. */
class StepsEstimateEngineTest {

    private fun g(ts: Long, x: Double, y: Double, z: Double) = GravitySample("t", ts, x, y, z)
    private fun p(motion: Double, steps: Double) = StepsEstimateEngine.CalibrationPoint(motion, steps)

    @Test fun motionIntensitySumsDeltas() {
        val grav = listOf(g(0, 0.0, 0.0, 1.0), g(1, 0.3, 0.0, 1.0), g(2, 0.3, 0.4, 1.0)) // 0.3 + 0.4
        assertEquals(0.7, StepsEstimateEngine.dayMotionIntensity(grav), 1e-9)
    }

    @Test fun motionIntensityEmptyAndSingle() {
        assertEquals(0.0, StepsEstimateEngine.dayMotionIntensity(emptyList()), 1e-9)
        assertEquals(0.0, StepsEstimateEngine.dayMotionIntensity(listOf(g(0, 0.0, 0.0, 1.0))), 1e-9)
    }

    @Test fun calibrateFitsMedianRatio() {
        // ratios 100,100,110,90,100 → median 100
        val pts = listOf(p(10.0, 1000.0), p(20.0, 2000.0), p(10.0, 1100.0), p(10.0, 900.0), p(10.0, 1000.0))
        val cal = StepsEstimateEngine.calibrate(pts)
        assertTrue(cal != null)
        assertEquals(100.0, cal!!.coefficient, 1e-9)
        assertTrue(!cal.manual)
        assertEquals(5, cal.sampleDays)
        assertTrue(cal.confidence > 0)
    }

    @Test fun calibrateNullBelowMinDays() {
        assertNull(StepsEstimateEngine.calibrate(listOf(p(10.0, 1000.0), p(10.0, 1000.0))))
    }

    @Test fun calibrateSkipsNearStillAndZeroStepDays() {
        val pts = listOf(p(0.2, 5000.0), p(10.0, 0.0), p(10.0, 1000.0), p(20.0, 2000.0), p(15.0, 1500.0))
        val cal = StepsEstimateEngine.calibrate(pts)
        assertTrue(cal != null)
        assertEquals(100.0, cal!!.coefficient, 1e-9)
        assertEquals(3, cal.sampleDays)
    }

    @Test fun manualOverrideWinsFullConfidence() {
        val cal = StepsEstimateEngine.calibrate(emptyList(), manualOverride = 123.0)
        assertTrue(cal != null)
        assertEquals(123.0, cal!!.coefficient, 1e-9)
        assertTrue(cal.manual)
        assertEquals(1.0, cal.confidence, 1e-9)
    }

    @Test fun tightFitMoreConfidentThanScattered() {
        val tight = (0 until 14).map { p(10.0, 1000.0) }
        val scattered = (0 until 14).map { i -> p(10.0, (500 + (i % 2) * 1500).toDouble()) }
        val ct = StepsEstimateEngine.calibrate(tight)!!
        val cs = StepsEstimateEngine.calibrate(scattered)!!
        assertTrue(ct.confidence > cs.confidence)
        assertEquals(1.0, ct.confidence, 1e-9)
    }

    @Test fun estimateAppliesCoefficient() {
        val cal = StepsEstimateEngine.Calibration(100.0, 5, 0.8, false)
        assertEquals(8700, StepsEstimateEngine.estimate(87.0, cal))
    }

    @Test fun estimateNullBelowMinMotion() {
        val cal = StepsEstimateEngine.Calibration(100.0, 5, 0.8, false)
        assertNull(StepsEstimateEngine.estimate(0.5, cal))
    }

    @Test fun estimateClampsAbsurd() {
        val cal = StepsEstimateEngine.Calibration(1_000_000.0, 5, 0.1, false)
        assertEquals(StepsEstimateEngine.MAX_DAILY_STEPS, StepsEstimateEngine.estimate(100.0, cal))
    }
}
