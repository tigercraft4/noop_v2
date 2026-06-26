import Foundation
import SwiftUI
import StrandAnalytics

/// The Report action behind every Test Centre Report button (spec section 5.2 flow). It assembles the
/// redacted, capped bundle for the active profile, presents the MANDATORY review-before-share sheet
/// (spec section 12) bound to the exact report.txt the user is about to share, and only on an explicit
/// confirm hands the bundle to TestReportFlow.run (which saves/shares it, opens the prefilled GitHub
/// issue, and toasts). No network of our own, no cloud.
///
/// This is the thin orchestrator that ties Group D's UI to the Group B/C contracts (TestBundleAssembler,
/// FileExport.exportBundle, ReportReviewGate, TestReportLink, TestReportFlow). It is an ObservableObject
/// so the screen can present the review sheet off `pendingReview`.
@MainActor
final class TestCentreReport: ObservableObject {

    /// A report pending the user's review. The screen presents a sheet bound to `gate.previewText` while
    /// this is non-nil; confirming calls `confirm()`, cancelling calls `cancel()`.
    struct Pending: Identifiable {
        let id = UUID()
        let profile: TestDomain
        let title: String
        var gate: ReportReviewGate
    }

    /// Non-nil while a report is awaiting review. Drive a `.sheet(item:)` off this.
    @Published var pending: Pending?

    /// A one-line status banner the screen can show after a share fires (the app has no global toast).
    @Published var lastStatus: String?

    /// Build the redacted bundle for `mode` and stage it for review. Nothing leaves the device yet.
    func start(mode: TestMode, live: LiveState) {
        let entries = TestBundleAssembler.assemble(profile: mode.domain, live: live)
        pending = Pending(profile: mode.domain, title: mode.title,
                          gate: ReportReviewGate(entries: entries))
    }

    /// The user read the report and confirmed: clear the gate and run the shipped share + deep-link flow.
    func confirm() {
        guard var p = pending else { return }
        p.gate.confirm()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        TestReportFlow.run(
            profile: p.profile, title: p.title,
            version: version, platform: platform, osVersion: osVersion,
            gate: p.gate,
            entries: p.gate.entries,
            showToast: { [weak self] msg in self?.lastStatus = msg },
            copyToPasteboard: { PlatformPasteboard.copy($0) })
        pending = nil
    }

    /// The user cancelled the review: nothing is shared.
    func cancel() { pending = nil }
}
