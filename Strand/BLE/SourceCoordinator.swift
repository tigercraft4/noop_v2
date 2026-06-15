import Foundation
import Combine
import WhoopStore

/// Runs exactly ONE device's live BLE at a time, driven by `DeviceRegistry.activeDeviceId`.
///
/// WHOOP-FIRST, ZERO REGRESSION
/// ----------------------------
/// This coordinator is a deliberate **NO-OP for the single-WHOOP user** (one row, id "my-whoop",
/// `peripheralId` nil, no other device). That is the default state and EVERY state where no second
/// device is paired: WHOOP is active, `setPreferredPeripheral(nil)` keeps "connect to the first WHOOP
/// found", the WHOOP's deviceId stays "my-whoop", and the existing WHOOP flow (`BLEManager` via
/// `AppModel.scan(...)`) runs exactly as it does today. On a plain launch with one WHOOP it issues NO
/// scan, NO disconnect, NO re-point — the only side effect is one `setPreferredPeripheral(nil)`, which
/// is the BLEManager default and a no-op there.
///
/// It only ever *acts* beyond that when the registry has more than the seeded WHOOP:
///
///   • switching TO a generic strap → `stopWhoop()` (BLEManager's existing `disconnect()`), then
///     `start` the isolated `StandardHRSource` for that strap's deviceId.
///   • switching BACK to WHOOP     → `stop()` the `StandardHRSource`, re-point the WHOOP connection to
///     the now-active WHOOP, then `startWhoop()` (BLEManager's existing scan entry point).
///   • switching WHOOP → a DIFFERENT WHOOP → tear down the current WHOOP link, set its preferred
///     peripheral + active deviceId to the new WHOOP, and reconnect.
///
/// It never imports or references `BLEManager`: the WHOOP start/stop AND the WHOOP targeting hooks
/// (preferred peripheral, active deviceId) are injected closures from the app model, so the two BLE
/// flows stay fully decoupled (mirrors `StandardHRSource`'s isolation). The one input it observes off
/// the BLE engine — `connectedPeripheralUUID` — arrives as a plain publisher, not the manager itself.
@MainActor
final class SourceCoordinator: ObservableObject {

    // MARK: - Dependencies

    private let registry: DeviceRegistry
    private let live: LiveState
    /// Resolves the shared on-device store for the strap persist closure (opened lazily by the app's
    /// `Repository`, matching the existing async store lifecycle — we never force it open early).
    private let storeHandle: () async -> WhoopStore?
    /// Re-trigger WHOOP's EXISTING scan/connect entry point (e.g. `AppModel.scan()` → `BLEManager.connect`).
    private let startWhoop: () -> Void
    /// Pause WHOOP via its EXISTING teardown (e.g. `AppModel.disconnect()` → `BLEManager.disconnect`).
    private let stopWhoop: () -> Void
    /// Pin the WHOOP connection to a specific strap (nil = first WHOOP found = single-WHOOP default).
    /// Wraps `BLEManager.setPreferredPeripheral`. Called only on a WHOOP transition.
    private let setWhoopPreferredPeripheral: (String?) -> Void
    /// Re-point which device id live WHOOP samples store under. Wraps `BLEManager.setActiveDeviceId`.
    /// Called only when the active WHOOP is NOT the seeded "my-whoop" — the legacy path never invokes it.
    private let setWhoopActiveDeviceId: (String) -> Void
    /// The most-recently-connected WHOOP peripheral's uuid, from `BLEManager.$connectedPeripheralUUID`.
    private let connectedPeripheralUUID: AnyPublisher<String?, Never>
    /// Diagnostic sink for the ISOLATED generic-HR source's connect lifecycle. Wired at the composition
    /// root (`AppModel`) to the SAME strap log `BLEManager` writes to (`live.append(log:)`), so generic-HR
    /// lines land in the one log the user exports (issue #421 — the Polar/Wahoo/Coospo/Garmin-HRM path was
    /// previously invisible). Passed straight into `StandardHRSource`. Defaults to a no-op so existing
    /// call sites (and tests) compile unchanged.
    private let straplog: (String) -> Void

    // MARK: - State

    /// The lazily-created generic-strap source. nil until the first switch to a strap; reused after.
    private var standardSource: StandardHRSource?
    /// The deviceId the `standardSource` is currently running for (so we don't churn on the same id).
    private var activeStrapId: String?
    /// True once we've transitioned onto a generic strap. While false (the default / WHOOP-active
    /// state), switching to WHOOP is a pure no-op — we never issue a redundant WHOOP (re)scan.
    private var onStrap = false
    /// The WHOOP device id we're currently pointed at, set the first time WHOOP becomes active and on
    /// every WHOOP→WHOOP re-point. nil until the first WHOOP activation is handled. Lets us tell "same
    /// WHOOP, no change" (no churn) from "a DIFFERENT WHOOP became active" (re-point + reconnect).
    private var activeWhoopId: String?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// - Parameters:
    ///   - registry: the Phase 1A device registry; `activeDeviceId` drives every transition.
    ///   - live: the shared `LiveState` the Live UI observes (fed by whichever source is running).
    ///   - storeHandle: resolves the shared `WhoopStore` for the strap persist closure.
    ///   - startWhoop: WHOOP's existing scan entry point (injected so we never touch `BLEManager`).
    ///   - stopWhoop: WHOOP's existing disconnect (injected for the same reason).
    ///   - setWhoopPreferredPeripheral: pin the WHOOP scan to one strap (nil = first found).
    ///   - setWhoopActiveDeviceId: re-point which id WHOOP samples store under (multi-WHOOP only).
    ///   - connectedPeripheralUUID: the BLE engine's last-connected WHOOP uuid, for identity adoption.
    ///   - straplog: connect-lifecycle diagnostics for the isolated `StandardHRSource`, wired to the same
    ///     strap log `BLEManager` uses (issue #421). Defaults to no-op so existing call sites compile.
    init(registry: DeviceRegistry,
         live: LiveState,
         storeHandle: @escaping () async -> WhoopStore?,
         startWhoop: @escaping () -> Void,
         stopWhoop: @escaping () -> Void,
         setWhoopPreferredPeripheral: @escaping (String?) -> Void,
         setWhoopActiveDeviceId: @escaping (String) -> Void,
         connectedPeripheralUUID: AnyPublisher<String?, Never>,
         straplog: @escaping (String) -> Void = { _ in }) {
        self.registry = registry
        self.live = live
        self.storeHandle = storeHandle
        self.startWhoop = startWhoop
        self.stopWhoop = stopWhoop
        self.setWhoopPreferredPeripheral = setWhoopPreferredPeripheral
        self.setWhoopActiveDeviceId = setWhoopActiveDeviceId
        self.connectedPeripheralUUID = connectedPeripheralUUID
        self.straplog = straplog
    }

    // MARK: - Wiring

    /// Begin observing `registry.activeDeviceId` AND the BLE engine's connected-peripheral uuid.
    /// `removeDuplicates()` collapses redundant emissions; the first activeDeviceId (WHOOP on a normal
    /// launch) is handled by `activeDeviceChanged` and, for the single WHOOP, does nothing but set the
    /// default preferred peripheral (nil) — no scan/disconnect churn. The connected-uuid sink drives
    /// first-connect identity adoption.
    func start() {
        registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in self?.activeDeviceChanged(to: id) }
            .store(in: &cancellables)

        connectedPeripheralUUID
            .removeDuplicates()
            .sink { [weak self] uuid in self?.connectedPeripheralChanged(to: uuid) }
            .store(in: &cancellables)
    }

    // MARK: - Transitions

    /// Resolve the device for `id` and reconcile which live source is running. Idempotent and guarded
    /// against redundant churn:
    ///   • A WHOOP, same one we're already on (incl. the single-WHOOP first launch) → DO NOTHING new.
    ///   • A DIFFERENT WHOOP → re-point the WHOOP connection (preferred peripheral + deviceId) + reconnect.
    ///   • WHOOP active after a strap → stop the strap source + resume WHOOP.
    ///   • A generic strap → pause WHOOP + (re)start `StandardHRSource` for that strap's id.
    func activeDeviceChanged(to id: String) {
        if isWhoop(id) {
            switchToWhoop(id: id)
        } else {
            switchToStrap(id: id)
        }
    }

    /// Active device is a WHOOP (`id`). Three sub-cases, all churn-guarded:
    ///   • We were already on this exact WHOOP and not on a strap → pure no-op (the dormant default;
    ///     the single-WHOOP launch lands here and touches nothing but the initial preferred-peripheral).
    ///   • We were on a generic strap → stop that source and resume WHOOP, pointed at this WHOOP.
    ///   • We were on a DIFFERENT WHOOP → drop that WHOOP link and reconnect to this one.
    private func switchToWhoop(id: String) {
        // Already streaming this exact WHOOP with no strap in between → nothing to do.
        if !onStrap, activeWhoopId == id { return }

        let peripheralId = peripheralId(for: id)

        if onStrap {
            // Coming back from a generic strap: tear that source down first.
            standardSource?.stop()
            standardSource = nil
            activeStrapId = nil
            onStrap = false
            pointWhoop(at: id, peripheralId: peripheralId)
            startWhoop()
        } else if activeWhoopId == nil {
            // First WHOOP activation of the session (the normal launch path). Set the targeting so the
            // existing WHOOP flow — already kicked off elsewhere on launch — uses it. For the single
            // seeded "my-whoop" (peripheralId nil, id "my-whoop") this is setPreferredPeripheral(nil)
            // and NO setActiveDeviceId / NO scan / NO disconnect: byte-for-byte today's behaviour.
            pointWhoop(at: id, peripheralId: peripheralId)
        } else {
            // WHOOP → a DIFFERENT WHOOP: drop the current link, re-point, and reconnect.
            stopWhoop()
            pointWhoop(at: id, peripheralId: peripheralId)
            startWhoop()
        }
    }

    /// Apply the WHOOP targeting for the now-active WHOOP `id`. Always sets the preferred peripheral
    /// (nil for the legacy "my-whoop" → connect to any WHOOP, unchanged). Re-points the sample deviceId
    /// ONLY for a non-legacy WHOOP — the seeded "my-whoop" keeps the bootstrap-set id, so the single-
    /// WHOOP path never calls `setActiveDeviceId`. Records `activeWhoopId` for future change detection.
    private func pointWhoop(at id: String, peripheralId: String?) {
        setWhoopPreferredPeripheral(peripheralId)
        if id != "my-whoop" {
            setWhoopActiveDeviceId(id)
        }
        activeWhoopId = id
    }

    /// Active device is a generic strap. Pause WHOOP (once, on the WHOOP→strap edge) and run the
    /// isolated `StandardHRSource` for this strap's deviceId. Re-running for the SAME id is a no-op.
    private func switchToStrap(id: String) {
        guard activeStrapId != id else { return }   // already streaming this strap → no churn

        // Leaving WHOOP for the first strap: pause WHOOP's BLE via its existing teardown.
        if !onStrap { stopWhoop() }

        // Switching strap→strap: stop the previous strap's source before starting the new one.
        if standardSource != nil { standardSource?.stop() }

        let source = StandardHRSource(
            live: live,
            deviceId: id,
            persist: { [storeHandle] streams in
                Task { if let store = await storeHandle() { try? await store.insert(streams, deviceId: id) } }
            },
            log: straplog)   // generic-HR lifecycle → the SAME exported strap log (issue #421)
        // CONNECT to the active strap's known peripheral, don't just scan. scan() only discovered + listed
        // it but never connected, so a Polar etc. showed as "found" yet never streamed (#421). connect()
        // reaches the cached peripheral by identifier (or scans-then-connects if not yet cached); a bare
        // scan is the fallback only when the registry row has no/invalid identifier.
        if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
            source.connect(uuid)
        } else {
            source.scan()
        }
        standardSource = source
        activeStrapId = id
        onStrap = true
    }

    // MARK: - Identity adoption

    /// The BLE engine connected to a WHOOP peripheral (`uuid`). Persist that stable identity onto the
    /// CURRENTLY ACTIVE device when it's a WHOOP and hasn't adopted one yet — so the legacy "my-whoop"
    /// learns its strap's id on first connect, and a freshly-paired WHOOP confirms its identity.
    ///
    /// Guards (so this never corrupts the registry):
    ///   • nil uuid (a disconnect/never-connected republish) → ignore.
    ///   • the active device is NOT a WHOOP (a generic strap is active) → ignore; this connection isn't ours.
    ///   • the active WHOOP already has a DIFFERENT non-nil peripheralId → a different strap connected;
    ///     LOG it and do NOT clobber the stored identity.
    ///   • it already matches → nothing to write.
    private func connectedPeripheralChanged(to uuid: String?) {
        guard let uuid else { return }

        let activeId = registry.activeDeviceId
        guard isWhoop(activeId),
              let device = registry.devices.first(where: { $0.id == activeId }) else { return }

        switch device.peripheralId {
        case .none:
            // First connect for this WHOOP row → adopt the strap's stable identity.
            registry.setPeripheralId(activeId, peripheralId: uuid)
        case .some(uuid):
            break                               // already adopted this exact strap → nothing to do
        case .some(let existing):
            // A DIFFERENT strap connected under this WHOOP row. Never silently overwrite — that would
            // mis-map another physical strap's samples onto this device. Log and leave the stored id.
            live.append(log: "Multi-WHOOP: active device \(activeId) is registered to strap \(existing) but \(uuid) connected — not overwriting.")
        }
    }

    // MARK: - Lookups / classification

    /// The stored `peripheralId` for a device id, if the registry knows it. nil for the legacy
    /// "my-whoop" until it adopts one (→ connect to any WHOOP, unchanged) and for an unknown id.
    private func peripheralId(for id: String) -> String? {
        registry.devices.first(where: { $0.id == id })?.peripheralId
    }

    /// Classify a device id as WHOOP vs a generic strap. WHOOP if the id is the canonical
    /// "my-whoop", or the registry row's `brand` is "WHOOP" (case-insensitive). Unknown ids default
    /// to WHOOP so the coordinator stays dormant rather than ever stealing the WHOOP's BLE.
    private func isWhoop(_ id: String) -> Bool {
        if id == "my-whoop" { return true }
        guard let device = registry.devices.first(where: { $0.id == id }) else { return true }
        return Self.isWhoop(device)
    }

    /// A device is WHOOP when its brand is "WHOOP" (the seeded `my-whoop` row's brand).
    static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop" || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
