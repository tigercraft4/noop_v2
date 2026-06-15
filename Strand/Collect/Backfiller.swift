import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → await insert (decoded durable) →
///   await enqueueRawBatch (raw durable) →
///   await setCursor(strap_trim) →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after decoded AND raw are both locally durable AND the ack
/// (.withResponse) is link-layer confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    typealias Extractor = ([ParsedFrame], Int, Int) -> Streams

    private let store: BackfillStoreWriting
    /// Device id offloaded chunks persist under. MUTABLE so a WHOOP↔WHOOP switch
    /// (BLEManager.setActiveDeviceId) re-attributes the next finishChunk persist immediately, rather
    /// than freezing the id captured at construction. Single-WHOOP never switches, so this stays
    /// "my-whoop" exactly as a `let` would have.
    var deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false
    /// Strap family for the current offload, set at begin(). Drives family-aware frame parsing (WHOOP 5/MG
    /// records sit at +4 offsets vs WHOOP 4.0) and the end_data slice the ack needs. Captured at begin()
    /// rather than init so it's correct even if the Backfiller was constructed before the strap was known.
    private var family: DeviceFamily = .whoop4

    /// Diagnostic sink (strap log). Surfaces historical records whose firmware layout we can't decode.
    private let log: ((String) -> Void)?
    /// Versions already reported this session, so the diagnostic logs each once (no spam).
    private var loggedUnmappedVersions: Set<Int> = []

    /// Per-session persistence tally — the success-side observability the log forensics flagged as the
    /// blind spot (#150): we logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't
    /// tell a banking strap from a broken one. Reset at begin(); read by BLEManager at session end to emit
    /// "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400).
    private(set) var sessionRowsPersisted = 0
    private(set) var sessionMotionRows = 0
    private var sessionNightKeys: Set<Int> = []
    var sessionNights: Int { sessionNightKeys.count }
    /// Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
    /// sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
    private var loggedNoCursor = false

    /// The trim cursor of the LAST chunk this Backfiller acked (durably persisted + confirmed to the
    /// strap). Survives across sessions on the same connection so the auto-continue gate (#364) can ask
    /// "did the offload actually advance the strap's trim this session?" — the spin-detector signal that
    /// stops it re-kicking forever when the cursor is frozen. nil until the first ack. NOT reset in
    /// `begin()` (it's a cross-session high-water mark, not a per-session tally).
    private(set) var lastAckedTrim: UInt32?

    /// Distinct historical layout versions logged this session. Unlike `loggedUnmappedVersions` (which
    /// only fires for layouts NOOP can't decode), this surfaces the layout on a HEALTHY sync too, so a
    /// shared strap log always reveals what the strap emits (v18/v24/v25/v26). Mirrors the Android
    /// Backfiller (PR #241, ryanbr); reset per session in `begin`.
    private var loggedLayoutVersions: Set<Int> = []

    /// Durably archives undecodable record frames BEFORE the trim ack (#77 / #91). Returns true once
    /// the bytes are safe (written OR cap-reached — either way the chunk may be acked) and false on a
    /// genuine write failure, in which case `finishChunk` holds the cursor/ack so the strap re-sends.
    /// nil in non-production inits (tests/preview) → archiving is skipped and acks proceed as before.
    private let rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)?
    /// Per-chunk outcome hook (#77 family): (didDecodeSensorRows, wasConsoleOnly). Lets BLEManager
    /// tally a session so a COMPLETED-but-empty offload (all console, no sensor records) can tell the
    /// user their strap isn't banking, without false-positiving a normal caught-up sync.
    private let onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)?

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)? = nil,
         onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)? = nil,
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.rejectedSink = rejectedSink
        self.onChunk = onChunk
        self.extract = extract
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin(family: DeviceFamily) {
        self.family = family
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        sessionRowsPersisted = 0
        sessionMotionRows = 0
        sessionNightKeys.removeAll(keepingCapacity: true)
        loggedNoCursor = false
        loggedLayoutVersions.removeAll(keepingCapacity: true)
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        // metadata.data begins at frame[7] (WHOOP4) / frame[11] (WHOOP5, the +4 puffin envelope); the
        // ack's end_data = data[10:18] → frame[17:25] (WHOOP4) or frame[21:29] (WHOOP5). The WHOOP5 slice
        // is verified on a real HISTORY_END (trim=112193 = frame[21..25]) in Whoop5HistoricalTests.
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// Pure per-chunk persistence tally (#150). `rows` = biometric rows actually inserted (HR, R-R, SpO2,
    /// skin-temp, resp, gravity — battery/events are housekeeping, not biometric history). `motion` =
    /// gravity rows (the sleep-critical signal). `nights` = the distinct day-keys (ts / 86400) the chunk's
    /// records covered. Summed across a session by finishChunk to drive the success summary line.
    nonisolated static func chunkTally(
        counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
        timestamps: [Int]
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
        return (rows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// The one-line session success summary (#150) — the success-side log that never existed. Returns nil
    /// when nothing persisted (so a console-only / caught-up session stays quiet and the existing
    /// empty-banking diagnostics speak instead).
    nonisolated static func sessionSummaryLine(rows: Int, motion: Int, nights: Int) -> String? {
        guard rows > 0 else { return nil }
        return "Backfill: session persisted \(rows) rows (\(motion) with motion) across \(nights) night(s)."
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame, family: family) else { return }

        // #150 forensics: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel — it has no
        // banked history to hand over. Surface it once so a log reads as a clock/charge state on the
        // strap, not a NOOP decode bug (retro-decode can't help here). The ack still proceeds below.
        if trim == 0xFFFFFFFF, !loggedNoCursor {
            loggedNoCursor = true
            log?("Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) — it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking.")
        }

        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            let parsed = frames.map { parseFrame($0, family: family) }
            // Observability (PR #241): log which layout this strap emits on a HEALTHY sync too — the
            // unmapped-version path below only fires for layouts NOOP can't decode, so a normal log
            // never revealed v18/v24/v25/v26. Once per distinct layout this session.
            if let v = parsed.lazy.compactMap({ $0.parsed["hist_version"]?.intValue }).first,
               loggedLayoutVersions.insert(v).inserted {
                log?("Backfill: historical records use layout v\(v)")
            }
            // Diagnostic (#30): a historical record whose firmware version we don't have a field map for
            // bails out of decode entirely — no HR, no R-R, no GRAVITY — so sleep (which is gravity/
            // motion-driven) can never be computed from it, even though the offload "completes". Surface
            // each unmapped version once so the user's strap log reveals what their firmware emits.
            // "Decoded nothing" must cover every mapped layout's signature field: v18 emits heart_rate,
            // v25 emits gravity_x (no per-second HR — it's PPG-derived), v26 emits ppg_waveform (no HR
            // either) — checking heart_rate alone false-flagged v25/v26 as unmapped (#156, sudden-break).
            for p in parsed {
                guard let v = p.parsed["hist_version"]?.intValue,
                      p.parsed["heart_rate"] == nil,
                      p.parsed["gravity_x"] == nil,
                      p.parsed["ppg_waveform"] == nil,
                      !loggedUnmappedVersions.contains(v) else { continue }
                loggedUnmappedVersions.insert(v)
                log?("Historical records use firmware layout v\(v), which NOOP doesn't decode yet — no motion data, so sleep can't be computed from the strap. Please report this (issue #30).")
            }
            let decoded = extract(parsed, ref.device, ref.wall)
            // Diagnostic (#77): the AGGREGATE silent-loss case — frames arrived but produced no rows at
            // all (CRC fail / unmapped layout / out-of-range timestamp), so this chunk persists nothing
            // yet still acks below and the strap trims past it. The per-version log above only catches
            // unmapped layouts; this catches CRC drops too. Observability only — behaviour unchanged
            // (not acking would wedge the offload on a re-send loop). Surfaces in the user's strap log.
            // Classify FIRST: separate genuinely-undecodable SENSOR records from the strap's own
            // type-50 console/diagnostic frames, which decode to 0 rows by design and are NOT a loss
            // (the "rejected frames" red herring users kept reporting — #77/#120). Drives both the
            // log wording below and the archive guard further down.
            let rejected = rejectedHistoricalRecords(frames, family: family)
            // Tally this chunk's outcome so a completed-but-empty session is distinguishable from a
            // caught-up one (#77 family): did it decode sensor rows, and was it console-only?
            onChunk?(!decoded.isEmpty, decoded.isEmpty && rejected.isEmpty)
            // A chunk that produced no rows AND held no genuine rejects was pure console output — say
            // so calmly so it doesn't read as data loss (the "rejected frames" red herring, #77/#120).
            if decoded.isEmpty && rejected.isEmpty {
                log?("Backfill: \(frames.count) frame(s) this chunk carried no sensor records (strap console/diagnostic output) — normal, nothing to persist (trim=\(trim)).")
            }
            // Log + hex-sample the GENUINE rejects whenever there are any — INCLUDING a partially-decoded
            // chunk (some good rows alongside CRC-failed / unmapped records), which used to archive those
            // raw bytes with no log line at all (only the all-empty case was observable). (ryanbr, PR #123)
            if !rejected.isEmpty {
                log?("Backfill: \(rejected.count) undecodable sensor record(s) of \(frames.count) frame(s) (trim=\(trim)) — archiving raw bytes before ack (CRC/unmapped layout).")
                // #91 / #30: dump a hex sample of the genuine rejects so an unmapped firmware's record
                // layout can be mapped from a user's strap log. Dump the FULL frame (not a 64-byte
                // prefix — v25/v26 records run ~84 B and the truncated tail is exactly where the
                // unmapped motion/HR fields sit), and sample a few more so one log carries enough
                // records to triangulate offsets. These only ever fire for unmapped firmware.
                for (i, f) in rejected.prefix(8).enumerated() {
                    let hex = f.map { String(format: "%02x", $0) }.joined()
                    log?("Backfill: rejected frame[\(i)] \(f.count)B: \(hex)")
                }
            }
            // Commit the decoded rows FIRST (durable). Doing this before the reject archive means a
            // rare insert failure — which returns and re-sends the whole chunk next session — can't
            // leave duplicate lines in the append-only reject archive.
            let counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
            do { counts = try await store.insert(decoded, deviceId: deviceId) } catch { return }
            // Success-side observability (#150): tally what actually persisted so the session can emit
            // "persisted N rows (M with motion) across K night(s)" — the win-rate signal a log never had.
            let tally = Backfiller.chunkTally(counts: counts, timestamps: decoded.gravity.map(\.ts) + decoded.hr.map(\.ts))
            sessionRowsPersisted += tally.rows
            sessionMotionRows += tally.motion
            sessionNightKeys.formUnion(tally.nights)

            // #77 / #91: any genuinely-undecodable type-47 record in this chunk must be ARCHIVED
            // before we ack — the ack frees the strap's copy, so the archive is the only remaining
            // copy of an unmapped firmware's records. A genuine archive write FAILURE aborts the
            // chunk (no setCursor, no ack) so the strap re-sends it next session — no data loss
            // either way. (A full archive is reported as success by the sink; we still ack.)
            if !rejected.isEmpty, let rejectedSink {
                guard rejectedSink(rejected, trim, family) else {
                    log?("Backfill: rejected-frame archive failed (trim=\(trim)) — holding ack so the strap re-sends.")
                    return
                }
            }

            // RAW: only persisted when the research toggle is ON. Default OFF → decoded-only; the
            // chunk is still durably committed (decoded) so the trim is safe to advance + ack.
            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch { return }
            }
        }
        do { try await store.setCursor("strap_trim", Int(trim)) } catch { return }

        ackTrim(trim, endData)
        lastAckedTrim = trim   // #364: record the advanced cursor for the auto-continue spin-detector
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
