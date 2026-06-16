import XCTest
@testable import Strand

/// Pins the #364 historical-sync auto-continue decision. The real bug: the strap offloads OLDEST-first
/// at ~60s/session with a 15-min floor and NO auto-continue, so on a deep backlog each connection drains
/// only one oldest pass then waits — "last night" can take many connections to reach even while the
/// strap stays connected. `BackfillContinuation.shouldAutoContinue` decides whether a session that ended
/// on the 60s IDLE cap (not a true HISTORY_COMPLETE) should immediately re-kick instead of tearing down
/// to the floor. Pure value type → no CoreBluetooth seam needed (mirrors MarginalRadioDetectorTests).
final class BackfillContinuationTests: XCTestCase {

    /// The happy path: still connected, the strap is well ahead of our frontier, the trim advanced this
    /// session, and we're under the cap ⇒ continue immediately.
    func testContinuesWhenConnectedBehindAndAdvancing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,            // strap newest
            ourFrontierTs: 1_800_000_000 - 86_400,   // our frontier a full day behind
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A dropped link must NOT auto-continue — the normal reconnect path owns it.
    func testStopsWhenDisconnected() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Caught up: the strap is NOT meaningfully ahead of our frontier ⇒ nothing left to fetch, don't spin.
    func testStopsWhenCaughtUp() {
        // Within the behind-gap (300s default): treat as caught up.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 120,      // only 2 min behind, under the 5-min gap
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Exactly at the gap boundary is NOT "behind" (strictly-greater), so it stops — caught-up wins ties.
    func testGapBoundaryIsNotBehind() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 300,      // exactly the 300s gap
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300))
        // One second past the gap IS behind.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 301,
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300))
    }

    /// The spin-detector: if the trim cursor did NOT advance this session (strap handing back
    /// console-only / refusing to trim), re-kicking would loop forever — so stop even though we're behind.
    func testStopsWhenTrimFrozen() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: false,                 // frozen cursor
            consecutiveCount: 0))
    }

    /// The hard per-connection cap: once we've already auto-continued maxAutoContinues times, stop and
    /// let the 15-min floor take over — a pathological strap can't pin the radio.
    func testStopsAtCap() {
        let cap = BackfillContinuation.defaultMaxAutoContinues
        // One below the cap still continues.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: true,
            consecutiveCount: cap - 1))
        // At the cap, stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: true,
            consecutiveCount: cap))
        // Above the cap, still stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: true,
            consecutiveCount: cap + 5))
    }

    /// Unknown range (no GET_DATA_RANGE yet, or no persisted frontier): we can't prove backlog remains,
    /// so don't auto-continue — let the periodic floor handle it conservatively.
    func testStopsWhenRangeUnknown() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_700_000_000,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: nil,                       // nothing persisted yet
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #451: GET_DATA_RANGE latched a STALE / wrong-epoch "newest" (e.g. a 2024 value when the real newest
    /// is 2026), which reads as BEHIND our frontier — the 2a "strap ahead" test fails and the old code
    /// concluded "caught up" and stopped after ONE session. But the trim advanced AND this session
    /// persisted real sensor rows, so the strap is demonstrably still handing over backlog ⇒ continue.
    func testContinuesWhenNewestStaleButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,            // stale 2023/24-epoch range answer…
            ourFrontierTs: 1_800_000_000,            // …reads as BEHIND our real 2026 frontier
            rowsPersistedThisSession: 240,           // but real rows came in this pass
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The discriminator that keeps the #451 fallback safe: a genuinely caught-up / console-only strap
    /// persists ZERO rows, so even with the trim nudging it must NOT spin — the 0-row fallback returns false.
    func testStopsWhenNewestStaleAndNoRows() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,            // stale/behind range answer
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 0,             // nothing actually persisted ⇒ caught up / stuck
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// GET_DATA_RANGE not answered at all (nil) but real rows are flowing and the trim advanced ⇒ keep
    /// draining. Without the rows fallback this would have stalled on the unknown-range guard.
    func testContinuesWhenRangeUnknownButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 180,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The rows-flowing fallback never overrides the earlier guards: a frozen trim, the cap, and a dropped
    /// link still stop even with rows > 0 (guards 1/3/4 are checked before 2b).
    func testRowsFallbackStillRespectsHardGuards() {
        // Frozen trim wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: false,                  // frozen cursor
            consecutiveCount: 0))
        // The cap wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: BackfillContinuation.defaultMaxAutoContinues))
        // A dropped link wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A multi-pass drain: a deep backlog continues pass after pass (each advancing the frontier toward
    /// the strap's newest) until either we catch up OR the cap is hit — never silently stalling at one.
    func testMultiPassDrainUntilCaughtUpOrCapped() {
        let strapNewest = 1_800_000_000
        var frontier = strapNewest - 7 * 86_400      // a full week behind
        var count = 0
        var passes = 0
        while BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: strapNewest,
            ourFrontierTs: frontier,
            lastTrimAdvanced: true,
            consecutiveCount: count) {
            // Each pass drains ~a day of the oldest backlog and counts as one auto-continue.
            frontier += 86_400
            count += 1
            passes += 1
            XCTAssertLessThanOrEqual(passes, BackfillContinuation.defaultMaxAutoContinues + 1,
                                     "auto-continue must be bounded — it can't loop forever")
        }
        // It stopped because it hit the cap (deep backlog), not because it silently stalled at pass 1.
        XCTAssertEqual(count, BackfillContinuation.defaultMaxAutoContinues)
    }
}
