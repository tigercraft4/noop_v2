import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Per-day sleep figures the WHOOP export carried verbatim (metricSeries rows written by
/// WhoopImporter under the imported deviceId). SleepView prefers these over its on-device
/// APPROXIMATE recomputations.
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?   // "sleep_performance", 0–100
    var consistencyPct: Double?   // "sleep_consistency", 0–100
    var needMin: Double?          // "sleep_need_min", minutes
    var debtMin: Double?          // "sleep_debt_min", minutes
}

// MARK: - Cross-source resolver model (PR#196 — fresher live charts/metrics)
//
// Product surfaces (Compare, Insights, Stress, Explore, Today) historically read rows under the EXACT
// requested source. That hid freshly-computed and Apple-compatible data that sat under a different
// device id. `Repository.resolvedSeries` resolves a metric over an explicit source PRECEDENCE — imported
// WHOOP wins, NOOP-computed fills the days it doesn't cover, and Apple Health only fills declared-
// compatible vitals on days neither strap source has. These types model that resolution; the exact-source
// reads (`series(key:source:)`) stay available for surfaces that must not mix sources.

/// One day's resolved value plus the source that actually supplied it (so a caption can name it).
struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let source: String
    let sourceKey: String
}

/// A candidate (source, key) pair the resolver will try, in precedence order.
struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String
    let key: String
}

/// The full result of resolving one metric: which sources were tried, and the merged per-day points.
struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]

    /// Plain `(day, value)` rows — the shape the chart/correlation code already consumes.
    var values: [(day: String, value: Double)] { points.map { ($0.day, $0.value) } }

    /// Distinct sources that actually contributed a point, in first-seen order (for a caption).
    var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }
}

/// Source provenance for daily rows before product surfaces merge them. The UI uses this to say
/// where a vital came from without changing the stored data.
enum DailyMetricSource: Equatable {
    case whoopImport
    case noopComputed
    case appleHealth
    case localCache

    var vitalPriority: Int {
        switch self {
        case .whoopImport:  return 0
        case .noopComputed: return 1
        case .appleHealth:  return 2
        case .localCache:   return 3
        }
    }
}

struct SourcedDailyMetric: Equatable {
    let metric: DailyMetric
    let source: DailyMetricSource
}

/// A compact snapshot of how much history each source holds, fed to the Data Sources "Freshness
/// Pipeline" card and the Android equivalent. Counts only — no per-day rows leave the refresh.
struct RepositoryFreshness: Equatable, Sendable {
    var importedDays: Int = 0
    var computedDays: Int = 0
    var appleDays: Int = 0
    var importedSleeps: Int = 0
    var computedSleeps: Int = 0
    var earliestDay: String?
    var latestDay: String?

    static let empty = RepositoryFreshness()

    var hasAnyHistory: Bool { importedDays > 0 || computedDays > 0 || appleDays > 0 }
}

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
final class Repository: ObservableObject {
    let deviceId: String
    /// Source id for on-device computed scores (recovery/strain/sleep derived from the raw strap
    /// streams by IntelligenceEngine). Merged UNDER the imported `deviceId` rows at read time, so a
    /// real WHOOP import always wins and the strap-only user still gets a populated dashboard.
    private var computedDeviceId: String { deviceId + "-noop" }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    /// Imported (export-verbatim) sleep figures by day. Empty until a WHOOP import lands.
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    /// How much history each source currently holds, recomputed on every `refresh()`. Powers the
    /// Data Sources "Freshness Pipeline" card so the user can see imported vs computed vs Apple coverage.
    @Published private(set) var freshness: RepositoryFreshness = .empty
    /// Daily metric rows with source provenance, used by vital-sign surfaces that need honest
    /// "WHOOP import / NOOP computed / Apple Health" captions instead of a silent merged row.
    @Published private(set) var vitalRows: [SourcedDailyMetric] = []
    /// Monotonic counter bumped on every successful `refresh()`. Intraday-updating views key their
    /// data load on this so they reload when fresh strap data lands — `today?.day` alone is a stable
    /// date string within a day and would freeze e.g. the Today HR trend until the date rolls over.
    @Published private(set) var refreshSeq = 0

    init(deviceId: String) { self.deviceId = deviceId }

    /// Today's row, by the device's LOGICAL local day — NOT just the newest stored row, which after a
    /// historical import was months-old data shown as today's hero (issue #23). The logical day rolls at
    /// 04:00 local (see `logicalDayKey`), so between midnight and 4am we keep resolving the prior logical
    /// day's row instead of an empty new-calendar-day row that blanks the dashboard (#144). nil if no row
    /// for that day yet (the dashboard then shows its empty/pending state). Presentation-only — stored
    /// row keys are untouched.
    ///
    /// Non-UTC pre-04:00 carve-out (#304): a user who falls asleep before midnight and wakes before the
    /// 04:00 rollover has the just-finished night banked under the NEW local calendar day (sleep is keyed
    /// by the local wake-day — `mergeSleep` / IntelligenceEngine), while `logicalDayKey` still points at
    /// yesterday. Resolving strictly by logical day would then surface the PREVIOUS night. So: if the
    /// local calendar day differs from the logical day AND a row for the local day has a banked night
    /// (`totalSleepMin != nil`), prefer that row. Otherwise fall back to the logical-day row — which keeps
    /// the #144 anti-blank guard (no night banked yet ⇒ keep yesterday's logical row, never blank).
    var today: DailyMetric? {
        let now = Date()
        return Repository.resolveToday(days: days,
                                       logicalKey: Repository.logicalDayKey(now),
                                       localKey: Repository.localDayKey(now))
    }

    /// Pure resolver behind `today` (extracted so the #304 boundary is testable without a live clock):
    /// prefer the LOCAL-calendar-day row when it differs from the logical day AND has a banked night
    /// (`totalSleepMin != nil`); otherwise the logical-day row (preserving the #144 anti-blank guard).
    /// `localKey == logicalKey` (the common daytime case) collapses to the plain logical-day lookup.
    nonisolated static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }
    /// The trailing 7 CALENDAR days ending today (for the week strip), oldest→newest — not the last 7
    /// stored rows, which on a stale import were old data. ISO yyyy-MM-dd compares chronologically.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// Source-aware rows for vital-sign cards. During previews/tests that set `days` directly,
    /// fall back to the merged local cache so the component still renders.
    var vitalMetricRows: [SourcedDailyMetric] {
        vitalRows.isEmpty ? days.map { SourcedDailyMetric(metric: $0, source: .localCache) } : vitalRows
    }

    /// Canonical source ids the resolver knows how to cross-reference. The strap's actual id is
    /// `deviceId` (and its computed sibling `deviceId + "-noop"`); these are the FIXED ids.
    static let whoopSource = "my-whoop"
    static let appleHealthSource = "apple-health"
    static let healthConnectSource = "health-connect"

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    nonisolated static let logicalDayRolloverHour = 4

    /// The LOGICAL local day for `now` — the calendar date of `now - rolloverHour hours`. Rolls at
    /// 04:00 local rather than midnight, so the small hours after midnight still resolve to the prior
    /// calendar date's row instead of an empty new-calendar-day row (#144). Pure + injectable so the
    /// boundary is testable (23:59 → same day, 01:00 → previous day, 04:01 → new day). Presentation-only:
    /// used solely to pick which stored row is Today and to anchor the Today HR-trend window start; stored
    /// row keys are never rewritten.
    static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        localDayKey(logicalDay(now, rolloverHour: rolloverHour))
    }

    /// Start of the logical day (its real calendar midnight) for `now`, in `calendar`'s zone — the anchor
    /// for the Today HR-trend window so it spans from the logical day's 00:00 rather than restarting at the
    /// new calendar midnight while we're still showing yesterday's logical day in the small hours (#144).
    static func logicalDayStart(_ now: Date, calendar: Calendar = .current,
                                rolloverHour: Int = logicalDayRolloverHour) -> Date {
        calendar.startOfDay(for: logicalDay(now, rolloverHour: rolloverHour))
    }

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        // Don't swallow the open failure with `try?` (#222): an import-time open failure (e.g. the iOS
        // data-protected store while the device is locked) was previously invisible, surfacing only as a
        // generic "Couldn't open the local store." Log the real error so the cause is diagnosable.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            NSLog("WhoopStore: ensureStore FAILED resolving DB path — \(error)")
            return nil
        }
        let s: WhoopStore
        do {
            s = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            NSLog("WhoopStore: ensureStore FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return nil
        }
        try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        store = s
        return s
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet — the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? []
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: fromDay, to: toDay)) ?? []
        let impSleep = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let compSleep = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []

        // Export-verbatim sleep figures (long-format metricSeries rows from WhoopImporter).
        // SleepView prefers these per day over its APPROXIMATE recomputations.
        let perf = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_performance", from: fromDay, to: toDay)) ?? []
        let cons = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_consistency", from: fromDay, to: toDay)) ?? []
        let need = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_need_min", from: fromDay, to: toDay)) ?? []
        let debt = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_debt_min", from: fromDay, to: toDay)) ?? []
        var fig: [String: ImportedSleepFigures] = [:]
        for p in perf { fig[p.day, default: ImportedSleepFigures()].performancePct = p.value }
        for p in cons { fig[p.day, default: ImportedSleepFigures()].consistencyPct = p.value }
        for p in need { fig[p.day, default: ImportedSleepFigures()].needMin = p.value }
        for p in debt { fig[p.day, default: ImportedSleepFigures()].debtMin = p.value }

        self.importedSleep = fig   // assigned BEFORE days/sleeps: one consistent publish per refresh
        self.days = Self.mergeDaily(imported: imported, computed: computed)
        self.sleeps = Self.mergeSleep(imported: impSleep, computed: compSleep)
        self.vitalRows = Self.sourceRows(imported: imported, computed: computed, apple: apple)
        self.freshness = Self.computeFreshness(imported: imported, computed: computed, apple: apple,
                                               importedSleeps: impSleep, computedSleeps: compSleep)
        self.loaded = true
        self.refreshSeq += 1
    }

    /// Per-source coverage counts for the Freshness Pipeline card. Pure over the rows already read.
    private static func computeFreshness(imported: [DailyMetric], computed: [DailyMetric],
                                         apple: [DailyMetric], importedSleeps: [CachedSleepSession],
                                         computedSleeps: [CachedSleepSession]) -> RepositoryFreshness {
        let days = (imported + computed + apple).map(\.day)
        return RepositoryFreshness(
            importedDays: imported.count,
            computedDays: computed.count,
            appleDays: apple.count,
            importedSleeps: importedSleeps.count,
            computedSleeps: computedSleeps.count,
            earliestDay: days.min(),
            latestDay: days.max()
        )
    }

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields.
    /// This preserves official export/import values while allowing fresh local analysis to populate
    /// Charge, skin temperature deviation, activity totals, or other fields missing from that row.
    nonisolated static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                byDay[d.day] = d.fillingNilFields(from: existing)
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Daily rows tagged with the source that supplied them, for the source-aware vital-sign cards.
    /// One entry per (source, day) — the consumer resolves precedence per metric (imported > computed
    /// > Apple); ordered by day, then source priority, so a stable list reaches the UI.
    private static func sourceRows(imported: [DailyMetric], computed: [DailyMetric],
                                   apple: [DailyMetric]) -> [SourcedDailyMetric] {
        (imported.map { SourcedDailyMetric(metric: $0, source: .whoopImport) }
            + computed.map { SourcedDailyMetric(metric: $0, source: .noopComputed) }
            + apple.map { SourcedDailyMetric(metric: $0, source: .appleHealth) })
            .sorted { lhs, rhs in
                if lhs.metric.day == rhs.metric.day {
                    return lhs.source.vitalPriority < rhs.source.vitalPriority
                }
                return lhs.metric.day < rhs.metric.day
            }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    /// Keys through `AnalyticsEngine.dayString(_:offsetSec:)` — the canonical LOCAL-day keyer
    /// `analyzeDay` attributes sessions with — NOT the unzoned `Repository.dayFormatter`, which formats
    /// in whatever the live device zone is and so disagreed with the engine's cached-offset attribution
    /// across a midnight boundary for non-UTC users (the Swift half of #406; mirrors the Android #304 fix
    /// pinned by MergeSleepLocalDayTest).
    private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        var byDay: [String: CachedSleepSession] = [:]
        for s in computed { byDay[endDay(s)] = s }
        for s in imported { byDay[endDay(s)] = s }
        return byDay.values.sorted { $0.startTs < $1.startTs }
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) for the strap, for a Today/24h trend chart.
    /// Aggregated in SQL so a full day never loads the raw ~1 Hz rows.
    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: bucketSeconds)) ?? []
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Every sleep BLOCK across BOTH sources, UN-deduplicated — so a split-sleep day (a nap
    /// + a main sleep, or any night recorded as multiple blocks) keeps ALL of its blocks.
    /// `sleeps` collapses each day to a single winner for the dashboard; this does not.
    ///
    /// Crucially this reads the on-device COMPUTED source (`computedDeviceId`) directly, not
    /// just the imported `deviceId`. A Bluetooth-only user (no WHOOP/Apple-Health import) has
    /// every block under the computed source, so a loader that only un-dedupes the imported
    /// device sees nothing to expand and silently falls back to the deduped one-per-day list —
    /// hiding the day's extra blocks. Imported blocks still win on any day they cover (matching
    /// the dashboard's imported-wins merge); computed blocks fill days with no import.
    /// Oldest→newest by onset.
    func allSleepSessions(days: Int = 4000) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        let imported = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var importedDays = Set<Date>()
        for s in imported { importedDays.insert(endDay(s)) }
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Hand-correct a night's bed (onset) and/or wake (end) time. `detectedStartTs` is the immutable
    /// detected key; the corrected onset is stored in `startTsAdjusted` so the key never moves (the
    /// recompute guard + daily override keep matching on it). The merged session list carries no source
    /// deviceId (same reason as the journal reads below), so this applies under BOTH the imported and
    /// computed sources — only the namespace that holds the night updates; the other is a no-op.
    ///
    /// Stages are **re-derived from the raw streams** for the corrected `[newStartTs, newEndTs]` window
    /// via `SleepStager.stageSession` — exactly what WHOOP does, so extending a boundary recovers real
    /// stages instead of a fabricated "awake" block. Only when the night has no raw data (an imported
    /// night) does it fall back to reshaping the stored summary (`SleepWindowReclip`). Refreshes so the
    /// hero re-reads the corrected night immediately.
    func editSleepTimes(detectedStartTs: Int, oldEndTs: Int, storedStagesJSON: String?,
                        newStartTs: Int, newEndTs: Int) async {
        guard let store = await ensureStore() else { return }
        // Raw streams live under the strap `deviceId`; read a 1h margin around the corrected window.
        let lo = newStartTs - 3_600, hi = newEndTs + 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let inWindowGravity = grav.lazy.filter { $0.ts >= newStartTs && $0.ts <= newEndTs }.count
        let windowSeconds = max(1, newEndTs - newStartTs)
        // Re-derive stages from raw only when the strap DENSELY covers the window (a real worn night) —
        // a couple of stray samples (e.g. an imported night with incidental strap data) must NOT trigger
        // a degenerate stageSession that overwrites a good breakdown. ~1 sample / 2 min is the floor.
        let hasStageableData = inWindowGravity >= max(20, windowSeconds / 120)

        let stagesJSON: String?
        if hasStageableData {
            let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
            let rr = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
            let resp = (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
            // Stage OFF the main actor — Repository is @MainActor and staging a multi-hour window from
            // tens of thousands of samples would otherwise freeze the UI on Save (mirrors analyzeRecent).
            let segs = await Task.detached(priority: .utility) {
                SleepStager.stageSession(start: newStartTs, end: newEndTs,
                                         grav: grav, hr: hr, rr: rr, resp: resp)
            }.value
            stagesJSON = AnalyticsEngine.encodeStages(segs)
        } else {
            // No usable strap data (imported night): reshape the stored summary on the wake side. Onset
            // edits on such nights move only the effective bedtime/`startTsAdjusted`, not the timeline.
            stagesJSON = SleepWindowReclip.reclip(stagesJSON: storedStagesJSON, sessionStart: detectedStartTs,
                                                  oldEnd: oldEndTs, newEnd: newEndTs)
        }
        // Apply to the source that actually OWNS this block. Try the computed source first; only fall
        // back to the imported source when no computed row matched — so we never edit a coincidental
        // same-startTs row in the other namespace (which the old unconditional double-write could do).
        let computedChanged = (try? await store.applySleepEdit(
            deviceId: computedDeviceId, detectedStartTs: detectedStartTs,
            newStartTs: newStartTs, newEndTs: newEndTs, stagesJSON: stagesJSON)) ?? 0
        if computedChanged == 0 {
            _ = try? await store.applySleepEdit(
                deviceId: deviceId, detectedStartTs: detectedStartTs,
                newStartTs: newStartTs, newEndTs: newEndTs, stagesJSON: stagesJSON)
        }
        await refresh()
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        return pts.map { ($0.day, $0.value) }
    }

    // MARK: - Cross-source resolver (PR#196)

    /// Product-facing daily series for a metric across every COMPATIBLE source, freshest-wins. Use this
    /// on surfaces where the user expects the best available signal (Compare/Insights/Stress/Explore/
    /// Today); use `series(key:source:)` where a single source must be honoured verbatim. Precedence is
    /// explicit per `sourceCandidates`: imported WHOOP > NOOP-computed > declared-compatible Apple Health.
    func resolvedSeries(key: String, source preferredSource: String, days: Int = 4000) async -> MetricSeriesResolution {
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: preferredSource,
                                               actualWhoopSource: deviceId)
        guard let store = await ensureStore() else {
            return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: [])
        }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))

        // First candidate wins per day; later candidates only fill days no earlier one covered.
        var byDay: [String: ResolvedMetricPoint] = [:]
        for candidate in candidates {
            let rows = await resolvedRows(store: store, candidate: candidate, from: from, to: to)
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        let points = byDay.values.sorted { $0.day < $1.day }
        return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: points)
    }

    /// Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
    /// for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
    /// columns but not the long-format series). Ascending by day.
    private func resolvedRows(store: WhoopStore, candidate: MetricSourceCandidate,
                             from: String, to: String) async -> [(day: String, value: Double)] {
        let metricRows = (try? await store.metricSeries(deviceId: candidate.source, key: candidate.key,
                                                        from: from, to: to)) ?? []
        var byDay = Dictionary(metricRows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        if let dailyRows = try? await store.dailyMetrics(deviceId: candidate.source, from: from, to: to) {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Self.dailyColumn(key: candidate.key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    /// The candidate (source, key) pairs to try for `key`, in precedence order, given the user's
    /// `preferredSource`. The strap's real id is `actualWhoopSource` (`deviceId`), so the computed
    /// sibling is `actualWhoopSource + "-noop"`.
    ///  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for vitals
    ///    that have a declared 1:1 mapping);
    ///  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
    ///    estimates and Apple may not carry);
    ///  • any other source → itself only (nutrition/mood are single-source by design).
    static func sourceCandidates(forKey key: String, preferredSource: String,
                                 actualWhoopSource: String) -> [MetricSourceCandidate] {
        let computedSource = actualWhoopSource + "-noop"
        func uniqued(_ cs: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
            var seen = Set<MetricSourceCandidate>(); var out: [MetricSourceCandidate] = []
            for c in cs where !seen.contains(c) { seen.insert(c); out.append(c) }
            return out
        }

        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: computedSource, key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        if preferredSource == appleHealthSource {
            var candidates = [MetricSourceCandidate(source: appleHealthSource, key: key)]
            // Health Connect is an Apple-equivalent body-metric source (Android only — harmless no-op on
            // iOS/Mac, which never write a "health-connect" series). Kept here so the resolver is
            // byte-identical to Android's, where it makes a Health-Connect-only weight history resolve in
            // Compare (#443). A real Apple export still wins per day; HC fills the rest.
            candidates.append(MetricSourceCandidate(source: healthConnectSource, key: key))
            if noopComputedCanFillAppleMetric(key) {
                candidates.append(MetricSourceCandidate(source: computedSource, key: key))
            }
            return uniqued(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    /// The Apple-Health series key that carries the SAME physiological quantity as a WHOOP key — used
    /// only for the declared-compatible vitals; nil means "no Apple equivalent, don't fall back to it".
    static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":              return "resting_hr"
        case "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal":
            return key
        case "sleep_total_min":  return "asleep_min"
        case "sleep_deep_min":   return "deep_min"
        case "sleep_rem_min":    return "rem_min"
        case "sleep_light_min":  return "core_min"
        default:                 return nil
        }
    }

    /// Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two daily
    /// totals the strap genuinely estimates (steps, calories) — never a derived WHOOP score.
    private static func noopComputedCanFillAppleMetric(_ key: String) -> Bool {
        switch key {
        case "steps", "active_kcal": return true
        default:                     return false
        }
    }

    /// The Explore read path (#199). Like `series(key:source:)` but, for the strap source
    /// ("my-whoop"), falls back to the on-device COMPUTED dailies a Bluetooth-only WHOOP 5 user
    /// has (no CSV/Health import) — so Charge/Rest/Effort/Health metrics still resolve. Three layers,
    /// imported-wins per day:
    ///  1. the imported metricSeries under `deviceId` (a real WHOOP export);
    ///  2. the COMPUTED metricSeries under `computedDeviceId` — for keys written there but absent from
    ///     the DailyMetric columns (notably `sleep_performance`, IntelligenceEngine's Rest composite);
    ///  3. the merged daily metrics (`self.days`, imported ∪ computed) for keys with a DailyMetric
    ///     column — the same key→column map InsightsView.dailyOutcome / Android's dailyPick use,
    ///     extended to the full daily column set.
    /// Any OTHER source (apple-health / nutrition-csv / noop-mood) reads only its own series, unchanged.
    func exploreSeries(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard source == "my-whoop" else { return await series(key: key, source: source, days: days) }
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))

        // day → value, lowest-priority source first; higher-priority sources overwrite per day so a
        // real import always wins over the computed strap value.
        var byDay: [String: Double] = [:]

        // Layer 3 (lowest): merged daily column for keys that have one. `self.days` is the published
        // imported ∪ computed daily cache (parameter `days` is the lookback window, not this).
        for d in self.days where byDay[d.day] == nil {
            if let v = Self.dailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        // Layer 2: computed metricSeries (covers sleep_performance, which has no daily column).
        let computedPts = (try? await store.metricSeries(deviceId: computedDeviceId, key: key, from: from, to: to)) ?? []
        for p in computedPts { byDay[p.day] = p.value }
        // Layer 1 (highest): the imported export's metricSeries.
        let importedPts = (try? await store.metricSeries(deviceId: deviceId, key: key, from: from, to: to)) ?? []
        for p in importedPts { byDay[p.day] = p.value }

        return byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
    }

    /// The merged DailyMetric column backing an Explore metric key, for the days the imported/computed
    /// metricSeries doesn't cover (strap-only WHOOP 5 users). Mirrors InsightsView.dailyOutcome and
    /// Android's dailyPick, extended to every Explore "my-whoop" key that maps to a daily column.
    /// Also handles the Apple-compatible sleep aliases (asleep_min / deep_min / rem_min / core_min) the
    /// resolver may request when filling an Apple candidate from its daily columns. Keys with no daily
    /// column (avg_hr / max_hr / sleep_performance …) return nil — they resolve from metricSeries only.
    private static func dailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery":         return d.recovery
        case "hrv":              return d.avgHrv
        case "rhr", "resting_hr": return d.restingHr.map(Double.init)
        case "strain":           return d.strain
        case "resp_rate":        return d.respRateBpm
        case "spo2":             return d.spo2Pct
        case "skin_temp":        return d.skinTempDevC
        case "sleep_total_min", "asleep_min": return d.totalSleepMin
        case "sleep_efficiency": return d.efficiency
        case "sleep_deep_min", "deep_min": return d.deepMin
        case "sleep_rem_min", "rem_min":   return d.remMin
        case "sleep_light_min", "core_min": return d.lightMin
        case "steps":            return d.steps.map(Double.init)
        case "active_kcal", "energy_kcal": return d.activeKcalEst
        default:                 return nil
        }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.metricKeys(deviceId: source)) ?? []
    }

    /// Native journal answers live under this dedicated source id. The journal table has no
    /// `source` column (PK is (deviceId, day, question)), so writing native answers under the
    /// imported `deviceId` would let a CSV re-import silently overwrite them — and clears could
    /// then delete imported rows. A separate device id keeps the two streams independent.
    static let journalDeviceId = "noop-journal"

    /// Logged behaviours (imported WHOOP journal ∪ native noop-journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let imported = (try? await store.journalEntries(deviceId: deviceId, from: from, to: to)) ?? []
        let native = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                      from: from, to: to)) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Imported journal rows only (used by the logging card to adopt the export's exact question
    /// strings into the catalog, so logged and imported days group under one behaviour).
    func importedJournalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.journalEntries(
            deviceId: deviceId,
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// One day's native answers (question → answeredYes) for the logging card's chip state. A
    /// targeted read — the merged list carries no deviceId, so it can't distinguish native rows.
    func nativeJournalAnswers(day: String) async -> [String: Bool] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        return Dictionary(rows.map { ($0.question, $0.answeredYes) },
                          uniquingKeysWith: { _, last in last })
    }

    /// Union; the NATIVE row wins per (day, question) — the in-app answer is the user's most recent
    /// explicit action and stays editable, unlike the immutable imported history.
    nonisolated static func mergeJournal(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    /// Write one native answer (day per the importer's wake-day convention).
    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.upsertJournal(
            [JournalEntry(day: day, question: question, answeredYes: answeredYes, notes: notes)],
            deviceId: Self.journalDeviceId)
    }

    /// Clear one native answer (never touches imported rows — scoped to the dedicated source id).
    func clearJournalAnswer(day: String, question: String) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteJournal(deviceId: Self.journalDeviceId, day: day, question: question)
    }

    /// All workouts (Whoop + Apple Health + on-device detected bouts), newest first.
    ///
    /// Detected bouts are surfaced with an honest "Detected" badge so the user can see — and
    /// dismiss or re-label — a duplicate the auto-detector created (#107). Dismissed detected spans
    /// are filtered HERE so every consumer (Workouts screen, Today, Coach context) agrees: the engine
    /// re-derives the detected rows each run, so a plain delete would resurrect them; the dismissed
    /// span list is the durable "not a workout" record.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows = (try? await store.workouts(deviceId: deviceId, from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: computedDeviceId, from: lo, to: hi, limit: 5000)) ?? []
        // Imported lifting sessions (Hevy / Liftosaur) live under their own "lifting" source.
        rows += (try? await store.workouts(deviceId: "lifting", from: lo, to: hi, limit: 5000)) ?? []
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        return rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
            .sorted { $0.startTs > $1.startTs }
    }

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete)
    //
    // Manual workouts live under the strap source (deviceId == `deviceId`, source "manual") — the same
    // place v1.67's live-tracked sessions already land (AppModel.endWorkout). Detected bouts live under
    // the computed `computedDeviceId` with sport "detected" and are wiped + re-derived each engine run,
    // so the only durable way to keep one hidden after a re-detect is the dismissed-span list below.

    /// The persisted dismissed detected spans ("startTs:endTs"). Read straight off UserDefaults so the
    /// read path and the write path share one source of truth (the engine never sees this — it always
    /// re-derives; only the read filter and these mutators consult it).
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// Persist a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from:
    ///  - editing a DETECTED bout ("Edit details…") replaces it with this manual row — the detected
    ///    original is dismissed durably so the re-detector doesn't bring it back (else both would show);
    ///  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale strap row
    ///    first (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
    ///  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add), so its
    ///    history is never touched.
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async {
        guard let store = await ensureStore() else { return }
        if let old, WorkoutSource.classify(old.source) == .detected {
            await dismissDetected(old)
        } else if let old, old.startTs != row.startTs || old.sport != row.sport {
            _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: old.sport,
                                                from: old.startTs, to: old.startTs)
        }
        _ = try? await store.upsertWorkouts([row], deviceId: deviceId)
    }

    /// Re-label a detected bout: copy it to a manual strap row with the chosen sport, then delete the
    /// detected original. This survives analyzeRecent — the engine wipes + re-derives only sport
    /// "detected" rows under the computed id AND skips any re-derived bout overlapping a real strap
    /// workout, which this copy now is — so the same session is never re-created as a duplicate. (#107)
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await ensureStore() else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes)
        _ = try? await store.upsertWorkouts([manual], deviceId: deviceId)
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: "detected",
                                            from: row.startTs, to: row.startTs)
    }

    /// Dismiss a DETECTED bout the user says isn't a workout. Records its span in the durable dismissed
    /// list (so a re-detect that recreates the same span stays hidden) AND deletes the current row so it
    /// disappears immediately. Idempotent: a span already present isn't duplicated. (#107)
    func dismissDetected(_ row: WorkoutRow) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) { spans.append(token); dismissedDetectedSpans = spans }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Delete ONE workout by natural key. The read model has no deviceId, so reconstruct it from the
    /// source: detected rows live under the computed id (and also get their span dismissed so they don't
    /// come back); everything else the screen can delete (manual) lives under the strap id.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected { await dismissDetected(row); return }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    // MARK: - Workout detail (read-only helpers, additive) — #410
    //
    // The workout-detail screen needs two reads over a single session's [startTs, endTs] window:
    // a downsampled HR curve (for the ChartCard) and the raw HR samples binned into zone-minutes
    // (for the zones bar). Both reuse the existing HR reads; they're thin convenience wrappers that
    // keep the bucket size / sample cap consistent with the rest of the app and give the view one
    // call site to await. NEVER mutate — pure reads.

    /// Downsampled HR over a workout window for the detail HR-curve. A short session wants a finer
    /// bucket than the Today 24h chart (300 s would flatten a 30-min run to ~6 points), so the bucket
    /// scales with duration: ~120 buckets across the window, floored at 15 s and capped at 300 s.
    func workoutHrBuckets(from: Int, to: Int) async -> [HRBucket] {
        guard to > from else { return [] }
        let span = to - from
        let bucket = max(15, min(300, span / 120))
        return await hrBuckets(from: from, to: to, bucketSeconds: bucket)
    }

    /// Raw HR samples binned into per-zone MINUTES for a workout window, using the age-derived
    /// (Tanaka) %HRmax zones — the same display zone model `WorkoutsView` already uses for imported
    /// zone percentages, but computed here from the strap's own samples so a session WITHOUT imported
    /// `zonesJSON` still gets a real time-in-zone split. Returns nil when the window carries no HR (so
    /// the view shows nothing rather than five empty bars). `age <= 0` falls back to a 30 y default —
    /// the zones are approximate either way and clearly labelled as such in the UI.
    func workoutZoneMinutes(from: Int, to: Int, age: Int) async -> [Double]? {
        guard to > from else { return nil }
        let samples = await hrSamples(from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let zoneSet = HRZones.zones(age: age > 0 ? Double(age) : 30)
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = tiz.seconds.map { $0 / 60.0 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// Shared formatter — created once. Hot read path (called per series window / refresh);
    /// allocating a DateFormatter per call was a measurable waste. Read-only use is thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
}

private extension DailyMetric {
    /// A copy of self where every nil field is backfilled from `fallback`. Used by the field-by-field
    /// daily merge so an imported export keeps its own values while a computed row fills the gaps it
    /// doesn't carry (e.g. on-device Charge / skin-temp deviation / activity totals).
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst
        )
    }
}
