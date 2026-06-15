import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    // NOTE: do NOT auto-clear `pairingHint` when `bonded` flips true. On a 5/MG, `bonded` is also set by
    // the live-HR shortcut (BLEManager — HR over the unbonded standard profile), so clearing the hint
    // there hides the still-accurate "free the strap" guidance from users who are streaming HR but never
    // got the real encrypted bond (issue #69). The genuine bond path clears the hint itself (the
    // CLIENT_HELLO ack), and a fresh connect attempt resets it.
    @Published public var bonded: Bool = false
    /// True ONLY when the link reached a GENUINE encrypted bond — the WHOOP 5/MG CLIENT_HELLO ack, the
    /// WHOOP 4 confirmed-write bond, or a restored already-bonded link. Deliberately NOT set by the
    /// live-HR shortcut that flips `bonded` true when HR streams over the *unbonded* standard profile on
    /// a 5/MG (issue #69) — so `bonded` can be true while `encryptedBond` is false ("Live HR, not fully
    /// paired"). WHOOP 4 always reaches a genuine bond, so the two track together there. Reset on
    /// connect/disconnect. Drives the Live pill's two-state distinction; the encrypted channel (buzz,
    /// alarm, double-tap, history offload) only works when this is true.
    @Published public var encryptedBond: Bool = false
    @Published public var heartRate: Int? = nil
    /// Whether the heavy R10/R11 realtime burst is currently armed (the "live feed"). Tracks the
    /// realtime INTENT (startRealtime/stopRealtime), NOT `heartRate` — the lightweight 0x2A37 profile
    /// keeps setting heartRate while bonded, so a heartRate-driven toggle could never read "off". The
    /// menu-bar Start/Stop-live-feed button reads this.
    @Published public var liveFeedActive: Bool = false
    /// Latest R-R packet exactly as it arrived from the strap. Keep this as the "fresh packet"
    /// surface for stress/breathing logic that reacts to the most recent arrival (and the standard
    /// 0x2A37 profile, which is the reliable R-R source). Drive it ONLY via `setRRIntervals(_:)`.
    @Published public var rr: [Int] = []
    /// Rolling UI buffer of recent R-R intervals (capped, oldest dropped first). Standard BLE HR
    /// notifications usually carry only one or two intervals per packet, so the Live console needs a
    /// separate short history to render an actually-moving R-R strip / rolling RMSSD. Appended (never
    /// replaced) by `setRRIntervals(_:)`; emptied by `clearBiometrics()`.
    @Published public private(set) var rrRecent: [Int] = []
    @Published public var batteryPct: Double? = nil
    /// Charging flag from the strap's BATTERY_LEVEL events — wire observation: u8 bit0 in the
    /// event payload (4.0 @26 / 5.0 @30), pushed ~every 8 min on captured links. nil until the
    /// first event of a session; cleared on disconnect so a stale flag can't outlive the link.
    /// Flag ONLY — the battery % keeps its family-specific source (#77).
    @Published public var charging: Bool? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// The strap's BLE advertising name, read back from firmware via GET_ADVERTISING_NAME_HARVARD
    /// (cmd 76 — sent in the connect handshake, parsed by FrameRouter). nil until the first reply.
    /// WHOOP 4.0 only; the rename control in Settings shows this as the strap's current name.
    @Published public var advertisingName: String? = nil
    /// Transient, human-readable result of the most recent strap-rename attempt — the
    /// SET_ADVERTISING_NAME_HARVARD ack, or a local validation message from BLEManager.renameStrap.
    /// Surfaced under the rename field; overwritten by the next attempt.
    @Published public var renameStatus: String? = nil
    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    // MARK: - Connection status (single source of truth, #266)

    /// Short connection-status label shared by the sidebar footer (RootView) and the Settings strap
    /// card, so the two can't disagree the way they did in #266 (sidebar "Connecting…" vs Settings
    /// "Connected" for the same connected-but-unbonded 5/MG link). Once the link is up and HR is
    /// flowing — even over the unbonded standard profile — this reads "Connected", never "Connecting…".
    public var connectionStatusLabel: String {
        if connected && bonded { return "Bonded · streaming" }
        if connected { return "Connected" }
        if bonded { return "Bonded · idle" }
        return "Disconnected"
    }
    /// True when the link is up (HR flowing) → status reads green. Drives the sidebar + Settings tone.
    public var connectionStatusIsActive: Bool { connected }
    /// True when previously paired but not currently connected → amber.
    public var connectionStatusIsIdle: Bool { !connected && bonded }

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?
    /// Fired (live only) when the strap reports it executed its firmware alarm
    /// (STRAP_DRIVEN_ALARM_EXECUTED). Wired by AppModel to re-arm the next day's alarm.
    public var onSmartAlarmFired: (() -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Set when an offload ended abnormally (the idle watchdog fired — the strap went quiet mid-sync),
    /// so a stalled history download isn't silent. Cleared by the next successful HISTORY_COMPLETE.
    /// Process-local on purpose (mirrors Android, ed6a31d): the next connect / 15-min tick re-offloads
    /// anyway, so persisting a stale error across launches would outlive its relevance.
    @Published public var lastSyncError: String? = nil

    /// True while a historical offload session is running, so screens can say "Syncing strap
    /// history…" instead of presenting half-loaded data as final (#77).
    @Published public var backfilling = false
    /// Chunks acked during the current offload session — an honest progress signal (total pending is
    /// unknowable from the protocol, so a count, never a percent).
    @Published public var syncChunksThisSession: Int = 0

    /// Undecodable HISTORICAL_DATA record frames seen this offload session whose raw bytes WERE
    /// preserved to the on-device archive (#77 / #91). Drives the honest "saved on this Mac" sync
    /// status. Reset at session start.
    @Published public var rejectedFramesThisSession: Int = 0
    /// Undecodable record frames the archive could NOT preserve this session (the ~5 MB cap was
    /// reached). Kept separate so the sync status never claims "saved" for bytes that were not.
    @Published public var rejectedFramesUnarchived: Int = 0
    /// Per-session chunk tallies that separate an EMPTY completed sync (the strap handed over only
    /// console/diagnostic frames — it isn't banking to flash, #77 family) from a clean one. Reset at
    /// session start. `decodedChunks == 0` with `consoleChunks` high ⇒ the strap's clock has lost sync.
    @Published public var decodedChunksThisSession: Int = 0
    @Published public var consoleChunksThisSession: Int = 0

    /// EXPERIMENTAL R22 telemetry (#174). How many of the 15 `enable_r22_*` SET_CONFIG flags the strap
    /// has ACKed since the last "Send enable sequence" tap — 15 means the strap accepted the whole
    /// sequence (hardware-confirmed: it returns a COMMAND_RESPONSE per flag). Reset on each new attempt.
    @Published public var r22FlagsAccepted: Int = 0
    /// Count of LIVE type-0x2F deep biometric records seen this session OUTSIDE a history offload — i.e.
    /// the R22 deep stream actually flowing in realtime. 0 with flags accepted = enable taken but no deep
    /// data yet (keep wearing it). Any non-zero = the prize: deep packets to decode. Reset per session.
    @Published public var deepPacketsThisSession: Int = 0

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    /// Number of WHOOP 5/MG ("puffin") frames captured this session (when frame capture is enabled in
    /// Settings → Experimental). Drives the capture status line + export button.
    @Published public var puffinCaptureCount: Int = 0
    /// On-disk location of the current puffin capture file, once anything has been flushed. The
    /// Settings "Export" / "Reveal" actions target this URL.
    @Published public var puffinCaptureURL: URL?

    /// Set when a WHOOP 5/MG strap refuses the encrypted bond on first connect ("Encryption/Authentication
    /// is insufficient") — CoreBluetooth won't start a fresh just-works bond against a strap still bonded to
    /// the official WHOOP app. Surfaced as actionable pairing-mode guidance; cleared once the link bonds.
    @Published public var pairingHint: String? = nil

    /// Set when a connect attempt fails because the strap wiped its bond ("Peer removed pairing
    /// information") — a firmware update, or the official WHOOP app re-bonding it. macOS keeps re-presenting
    /// the now-stale pairing key, so reconnects loop on the same error with no recovery. Carries an
    /// actionable forget-and-re-pair guide; cleared on the next successful connect. (5/MG firmware reset, 2026-06)
    @Published public var reconnectGuide: String? = nil

    /// Set when NOOP detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime
    /// stream (#80 — a 2016 Mac / OpenCore drops the link the instant that high-bandwidth burst is armed).
    /// After repeated arm-then-timeout cycles NOOP stops arming the heavy stream and falls back to the
    /// low-bandwidth 0x2A37 standard Heart Rate profile, so live HR can still flow on a radio that otherwise
    /// looped forever. Informational note for the Live screen; cleared on a clean reconnect or Live re-open.
    @Published public var standardHRMode: String? = nil

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    /// Single funnel for R-R intervals from EITHER source (the standard 0x2A37 profile in BLEManager,
    /// the REALTIME_DATA frame in FrameRouter). Updates the fresh-packet `rr` AND appends the valid
    /// intervals onto the bounded `rrRecent` rolling buffer so the Live console can show a moving
    /// strip. Non-positive sentinels (a strap "no interval this beat" placeholder) are dropped from the
    /// rolling buffer. `recentLimit` caps the buffer; the oldest intervals fall off first.
    public func setRRIntervals(_ intervals: [Int], recentLimit: Int = 60) {
        rr = intervals
        let valid = intervals.filter { $0 > 0 }
        guard !valid.isEmpty else { return }
        rrRecent.append(contentsOf: valid)
        if rrRecent.count > recentLimit {
            rrRecent.removeFirst(rrRecent.count - recentLimit)
        }
    }

    /// Blank all live biometric readouts (HR + R-R + the rolling buffer) so a stale heart rate or
    /// R-R strip can't outlive the link. Called on CoreBluetooth disconnect (BLEManager), the twin of
    /// the `charging = nil` / `encryptedBond = false` clears on the same path.
    public func clearBiometrics() {
        heartRate = nil
        rr.removeAll()
        rrRecent.removeAll()
    }

    public func append(log line: String) {
        log.append(Self.redactPii(line))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Scrub personal identifiers from a strap-log line so it's safe to share publicly (#445): BLE MAC
    /// addresses are masked to their first + last byte, and the WHOOP's SERIAL — carried in its device
    /// name ("WHOOP 4C1594026") and tied to the owner's account — is removed. Applied at the single log
    /// sink (BLEManager + the generic-HR diagnostics both feed it). MACs require colons, so hex command
    /// payloads are untouched; the dotted model names ("WHOOP 4.0"/"5.0") don't match the serial pattern.
    static func redactPii(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})",
            with: "$1:••:••:••:••:$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "WHOOP (\\d[0-9A-Za-z]{5,})", with: "WHOOP <serial>", options: .regularExpression)
        return out
    }
}
