//
//  ProctoringEngine.swift
//  Weft — native macOS port of the proctoring DETECTION engine.
//
//  This is the Swift/AppKit equivalent of the Electron checks that used to live
//  in Tessera's main.js (detectScreenCapture, detectRemoteSession, detectDisplays,
//  detectVM, the network/public-IP comparison) and how renderer/student.js wired
//  them together in runChecks() / monitorTick().
//
//  Design notes:
//    - Everything here is DETECTION only. It gathers signals and returns a
//      ProctoringReport. It never blocks, kills processes, opens windows, or
//      shells out for remediation. The UI / kiosk layer decides what to do with
//      the report (mirrors student.js setCheck()).
//    - All native APIs are wrapped so the file compiles and runs on a plain
//      macOS build with no special entitlements. The two pieces that DO need
//      entitlements (continuous webcam capture and periodic screenshots) are
//      marked TODO below and are intentionally not implemented here.
//    - No external packages. AppKit + Foundation only.
//
//  Parity map (Electron -> here):
//    detectDisplays            -> NSScreen.screens.count
//    detectScreenCapture       -> NSWorkspace.shared.runningApplications scan
//    Screen Recording grant    -> CGPreflightScreenCaptureAccess()
//    detectRemoteSession       -> running-app scan (screensharingd-style names)
//    detectVM                  -> sysctlbyname("hw.model"/"machdep.cpu...") + IOPlatformExpertDevice
//    getPublicIP + ip equality -> URLSession GET https://api.ipify.org, compare to teacherIP
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(IOKit)
import IOKit
#endif

// MARK: - Report

/// The full set of proctoring signals gathered in one sweep. This is the native
/// analogue of the per-check fields student.js writes to the `students` row
/// (ip_match, remote_session, screen_capture, display_count, is_vm) plus the
/// public IP it captured. Pure data; safe to hand to SwiftUI.
struct ProctoringReport: Sendable, Equatable {
    /// True when the student's public IP equals the teacher's. Mirrors
    /// `ipMatch = studentIP === session.teacher_ip`. When `teacherIP` was nil
    /// (nothing to compare against) this stays `true` so it never false-fails.
    var networkSame: Bool

    /// A remote-control / screen-sharing daemon or app looks active
    /// (screensharingd, VNC, TeamViewer, etc). Mirrors detectRemoteSession().
    var remote: Bool

    /// Screen-share / screen-recording / remote-control SOFTWARE is running.
    /// Mirrors detectScreenCapture().active.
    var screenCapture: Bool

    /// Count of attached displays. Mirrors detectDisplays() (== NSScreen count).
    var displays: Int

    /// This machine looks like a virtual machine. Mirrors detectVM().
    var isVM: Bool

    /// The student's public IP as seen by api.ipify.org, or nil if it could not
    /// be fetched (offline / timed out). student.js stored this as `ip`.
    var publicIP: String?

    // ── Detail strings (optional, for the teacher-facing labels) ───────────

    /// Human-readable reason a remote session was flagged, if any.
    var remoteReason: String?

    /// The matched VM signal string (e.g. "VMware", "Parallels"), if any.
    var vmSignal: String?

    /// The set of detected sharing/recording/remote apps, by display name.
    /// student.js joined this list for the "capture" check label.
    var detectedApps: [String]

    /// True when macOS Screen Recording permission is granted. Required before
    /// the (TODO) periodic-screenshot feature can produce a usable frame; the
    /// pre-exam screen also surfaces this so the teacher knows captures will work.
    var screenRecordingPermission: Bool

    init(
        networkSame: Bool = true,
        remote: Bool = false,
        screenCapture: Bool = false,
        displays: Int = 1,
        isVM: Bool = false,
        publicIP: String? = nil,
        remoteReason: String? = nil,
        vmSignal: String? = nil,
        detectedApps: [String] = [],
        screenRecordingPermission: Bool = false
    ) {
        self.networkSame = networkSame
        self.remote = remote
        self.screenCapture = screenCapture
        self.displays = displays
        self.isVM = isVM
        self.publicIP = publicIP
        self.remoteReason = remoteReason
        self.vmSignal = vmSignal
        self.detectedApps = detectedApps
        self.screenRecordingPermission = screenRecordingPermission
    }
}

// MARK: - Engine

/// Gathers proctoring signals natively. One instance can be reused for the
/// initial pre-exam sweep (runChecks) and the in-exam periodic re-sweep
/// (monitorTick) — call `runChecks(teacherIP:)` again on a timer.
final class ProctoringEngine {

    init() {}

    /// Run the full detection sweep. Network probe (public IP) and the app /
    /// system probes run concurrently; everything else is local and fast.
    /// - Parameter teacherIP: the teacher's public IP to compare against, or
    ///   nil to skip the network-equality check (treated as a pass).
    func runChecks(teacherIP: String?) async -> ProctoringReport {
        // Kick off the (slow, network) public-IP fetch concurrently with the
        // local probes so the sweep is bounded by the network call, not serial.
        async let publicIPTask = fetchPublicIP()

        let displays = detectDisplayCount()
        let screenPermission = detectScreenRecordingPermission()
        let appScan = detectSharingAndRemoteApps()
        let vm = detectVM()

        let publicIP = await publicIPTask

        // Network equality: only a real mismatch fails. If we have no teacher IP
        // to compare against, or we couldn't read our own public IP, don't
        // false-fail — student.js only flagged on a concrete inequality.
        let networkSame: Bool
        if let teacher = teacherIP, !teacher.isEmpty, let mine = publicIP {
            networkSame = (mine == teacher)
        } else {
            networkSame = true
        }

        return ProctoringReport(
            networkSame: networkSame,
            remote: appScan.remoteActive,
            screenCapture: appScan.active,
            displays: displays,
            isVM: vm.isVM,
            publicIP: publicIP,
            remoteReason: appScan.remoteReason,
            vmSignal: vm.signal,
            detectedApps: appScan.detectedApps,
            screenRecordingPermission: screenPermission
        )
    }

    // MARK: Displays — NSScreen.screens.count

    /// Mirrors detectDisplays() / screen.getAllDisplays().length. One screen is
    /// the expected single-monitor case; more is a soft warning upstream.
    func detectDisplayCount() -> Int {
        #if canImport(AppKit)
        return max(1, NSScreen.screens.count)
        #else
        return 1
        #endif
    }

    // MARK: Screen-recording PERMISSION — CGPreflightScreenCaptureAccess()

    /// Whether macOS Screen Recording permission is granted for this app. This
    /// is the permission GATE, not a detection of other software. The Electron
    /// side read systemPreferences.getMediaAccessStatus('screen'); the native
    /// equivalent that does NOT trigger a prompt is CGPreflightScreenCaptureAccess.
    func detectScreenRecordingPermission() -> Bool {
        #if canImport(CoreGraphics)
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            // Pre-Catalina had no screen-recording gate; treat as granted.
            return true
        }
        #else
        return false
        #endif
    }

    // MARK: Screen-share / recording / remote-control SOFTWARE

    /// Result of scanning the running-application list.
    struct AppScanResult: Sendable, Equatable {
        /// Any sharing/recording/remote-control app is running.
        var active: Bool
        /// A remote-control / screen-sharing tool specifically is running
        /// (the detectRemoteSession() flavour — someone could be driving/
        /// watching the machine right now).
        var remoteActive: Bool
        /// Reason string for the remote flag, if any.
        var remoteReason: String?
        /// Display names of every matched app.
        var detectedApps: [String]
    }

    /// One pattern in the watch list. `name` is the teacher-facing label;
    /// `remote` marks tools that let another person drive or watch this
    /// machine (those also set the `remote` report flag, mirroring how
    /// detectRemoteSession() and detectScreenCapture() overlapped in Tessera).
    private struct AppPattern {
        let name: String
        /// Lowercased substrings matched against the bundle id and app name.
        let needles: [String]
        let remote: Bool
    }

    /// Ported from main.js SHARING_PATTERNS, adapted to bundle-id / app-name
    /// matching (NSWorkspace gives us those directly, so we don't need the
    /// `ps`-output regexes). `remote: true` are the remote-control / screen-
    /// sharing / phone-mirroring tools (the old "block" + remote-session set);
    /// `remote: false` are conferencing / recording tools (the old "warn" set).
    private let appPatterns: [AppPattern] = [
        // ── Remote-control / desktop sharing ───────────────────────────────
        AppPattern(name: "TeamViewer", needles: ["teamviewer"], remote: true),
        AppPattern(name: "AnyDesk", needles: ["anydesk"], remote: true),
        AppPattern(name: "Chrome Remote Desktop",
                   needles: ["chromeremotedesktop", "remoting_me2me_host", "chromoting", "chrome remote desktop"],
                   remote: true),
        AppPattern(name: "Parsec", needles: ["parsec"], remote: true),
        AppPattern(name: "RustDesk", needles: ["rustdesk"], remote: true),
        AppPattern(name: "Sunshine (game-stream host)", needles: ["sunshine"], remote: true),
        AppPattern(name: "Splashtop", needles: ["splashtop"], remote: true),
        AppPattern(name: "LogMeIn", needles: ["logmein"], remote: true),
        AppPattern(name: "GoToMyPC / GoToAssist", needles: ["gotomypc", "gotoassist"], remote: true),
        AppPattern(name: "NoMachine", needles: ["nomachine"], remote: true),
        AppPattern(name: "ConnectWise / ScreenConnect", needles: ["screenconnect", "connectwise"], remote: true),
        AppPattern(name: "BeyondTrust / Bomgar", needles: ["bomgar", "beyondtrust"], remote: true),
        AppPattern(name: "Zoho Assist", needles: ["zohoassist", "zoho assist"], remote: true),
        AppPattern(name: "DameWare", needles: ["dameware"], remote: true),
        AppPattern(name: "Microsoft Remote Desktop", needles: ["microsoft remote desktop", "com.microsoft.rdc"], remote: true),
        AppPattern(name: "Apple Screen Sharing", needles: ["screensharingd", "applevncserver", "ardagent", "screen sharing", "com.apple.screensharing"], remote: true),
        AppPattern(name: "VNC server/viewer", needles: ["vncviewer", "vncserver", "tightvnc", "tigervnc", "realvnc", "ultravnc", "vnc viewer", "winvnc"], remote: true),
        AppPattern(name: "iPhone Mirroring", needles: ["iphone mirroring", "com.apple.scrcd"], remote: true),

        // ── Phone / device mirroring ───────────────────────────────────────
        AppPattern(name: "Reflector", needles: ["reflector"], remote: true),
        AppPattern(name: "ApowerMirror", needles: ["apowermirror"], remote: true),
        AppPattern(name: "LetsView", needles: ["letsview"], remote: true),
        AppPattern(name: "Scrcpy (Android mirror)", needles: ["scrcpy"], remote: true),
        AppPattern(name: "Vysor", needles: ["vysor"], remote: true),
        AppPattern(name: "AirDroid", needles: ["airdroid"], remote: true),

        // ── Conferencing apps that can screen-share ────────────────────────
        AppPattern(name: "Zoom", needles: ["us.zoom", "zoom.us", "zoom"], remote: false),
        AppPattern(name: "Microsoft Teams", needles: ["com.microsoft.teams", "msteams", "ms-teams", "microsoft teams"], remote: false),
        AppPattern(name: "Cisco Webex", needles: ["webex", "webexmta"], remote: false),
        AppPattern(name: "Discord", needles: ["discord"], remote: false),
        AppPattern(name: "Slack", needles: ["com.tinyspeck.slackmacgap", "slack"], remote: false),
        AppPattern(name: "Skype", needles: ["skype"], remote: false),
        AppPattern(name: "BlueJeans", needles: ["bluejeans"], remote: false),
        AppPattern(name: "GoToMeeting", needles: ["gotomeeting", "g2mlauncher"], remote: false),
        AppPattern(name: "Jitsi", needles: ["jitsi"], remote: false),

        // ── Screen recording / streaming ───────────────────────────────────
        AppPattern(name: "OBS Studio", needles: ["com.obsproject.obs-studio", "obs studio", "obs"], remote: false),
        AppPattern(name: "Streamlabs Desktop", needles: ["streamlabs"], remote: false),
        AppPattern(name: "XSplit", needles: ["xsplit"], remote: false),
        AppPattern(name: "Camtasia", needles: ["camtasia"], remote: false),
        AppPattern(name: "ScreenFlow", needles: ["screenflow"], remote: false),
        AppPattern(name: "Loom", needles: ["loom"], remote: false),
        AppPattern(name: "Snagit", needles: ["snagit"], remote: false),
        AppPattern(name: "Bandicam", needles: ["bandicam"], remote: false),
        AppPattern(name: "CleanShot X", needles: ["cleanshot"], remote: false),
        AppPattern(name: "Kap", needles: ["com.wulkano.kap", "kap"], remote: false),
        AppPattern(name: "Riverside", needles: ["riverside"], remote: false),
        AppPattern(name: "ShareX", needles: ["sharex"], remote: false),
    ]

    /// Scan NSWorkspace.shared.runningApplications for any sharing / recording /
    /// remote-control app. This combines the roles of detectScreenCapture() and
    /// the macOS branch of detectRemoteSession() — the app-list scan is the part
    /// that ports cleanly to a sandboxed-friendly native API. (The shell probes
    /// detectRemoteSession() also used — ps for screensharingd, ifconfig for VPN
    /// tunnels, SSH_TTY — are not available without spawning helpers; the
    /// remote-control app match below covers the screen-sharing/VNC case.)
    func detectSharingAndRemoteApps() -> AppScanResult {
        #if canImport(AppKit)
        var matched: [String] = []
        var matchedRemote: [String] = []
        var seen = Set<String>()

        for runningApp in NSWorkspace.shared.runningApplications {
            // Build a single lowercased haystack from bundle id + localized name
            // + executable URL path so a needle hits whichever identifier exists.
            var hayParts: [String] = []
            if let bid = runningApp.bundleIdentifier { hayParts.append(bid) }
            if let n = runningApp.localizedName { hayParts.append(n) }
            if let url = runningApp.executableURL { hayParts.append(url.path) }
            if let url = runningApp.bundleURL { hayParts.append(url.lastPathComponent) }
            let hay = hayParts.joined(separator: " ").lowercased()
            if hay.isEmpty { continue }

            for pattern in appPatterns {
                guard pattern.needles.contains(where: { hay.contains($0) }) else { continue }
                if seen.insert(pattern.name).inserted {
                    matched.append(pattern.name)
                    if pattern.remote { matchedRemote.append(pattern.name) }
                }
                break // one pattern per app is enough
            }
        }

        let remoteReason = matchedRemote.isEmpty
            ? nil
            : "Remote-control / screen-sharing software running: " + matchedRemote.joined(separator: ", ")

        return AppScanResult(
            active: !matched.isEmpty,
            remoteActive: !matchedRemote.isEmpty,
            remoteReason: remoteReason,
            detectedApps: matched
        )
        #else
        return AppScanResult(active: false, remoteActive: false, remoteReason: nil, detectedApps: [])
        #endif
    }

    // MARK: VM detection — sysctl + IOPlatformExpertDevice

    /// Result of the VM heuristics.
    struct VMResult: Sendable, Equatable {
        var isVM: Bool
        var signal: String?
    }

    /// Substrings that betray a hypervisor in hw.model / ioreg, ported from
    /// netdisp.js VM_HW_MODEL_PATTERNS + VM_IOREG_PATTERNS.
    private static let vmSignatures: [String] = [
        "vmware", "parallels", "virtualbox", "innotek", "qemu", "kvm",
        "xen", "hvm domu", "virtual machine", "hyper-v", "microsoft corporation",
        "apple virtualization", "vz "
    ]

    /// Mirrors detectVM() + detectVMAdvanced(): check `hw.model`, the CPU brand /
    /// features, and the IOPlatformExpertDevice tree for hypervisor fingerprints.
    /// Real Macs report hw.model like "Mac15,3"; VM guests report "VMware7,1",
    /// "Parallels20,1", "VirtualBox", etc.
    func detectVM() -> VMResult {
        // (1) hw.model — fastest and hardest to spoof from userspace.
        if let model = Self.sysctlString("hw.model") {
            if let hit = Self.matchVMSignature(model) {
                return VMResult(isVM: true, signal: hit)
            }
        }

        // (2) CPU brand string + features. Hypervisors often leave a fingerprint
        // here (machdep.cpu.brand_string can read "Apple Virtualization ...",
        // and the "VMM" feature flag appears under a hypervisor).
        for key in ["machdep.cpu.brand_string", "machdep.cpu.features", "machdep.cpu.vendor"] {
            if let value = Self.sysctlString(key), let hit = Self.matchVMSignature(value) {
                return VMResult(isVM: true, signal: hit)
            }
        }
        // The hypervisor-present sysctl ("kern.hv_vmm_present") is a strong
        // direct signal where available.
        if Self.sysctlBoolIsTrue("kern.hv_vmm_present") {
            return VMResult(isVM: true, signal: "hypervisor present")
        }

        // (3) IOPlatformExpertDevice — deeper check; even with sysctl scrubbed
        // the platform tree usually still names the hypervisor vendor.
        if let hit = Self.ioPlatformVMSignal() {
            return VMResult(isVM: true, signal: hit)
        }

        return VMResult(isVM: false, signal: nil)
    }

    /// Read a string-valued sysctl by name. Returns nil on any failure.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Read an integer-valued sysctl and report whether it is nonzero.
    private static func sysctlBoolIsTrue(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }

    /// Return the matched VM signature substring (original-cased fragment) if
    /// `text` contains any known hypervisor fingerprint.
    private static func matchVMSignature(_ text: String) -> String? {
        let lower = text.lowercased()
        for sig in vmSignatures where lower.contains(sig) {
            // Surface a readable signal: prefer the recognizable vendor token.
            return sig.trimmingCharacters(in: .whitespaces).capitalized
        }
        return nil
    }

    /// Inspect IOPlatformExpertDevice for hypervisor strings. Best-effort; if
    /// IOKit isn't available or the lookups fail, returns nil (not a VM signal).
    private static func ioPlatformVMSignal() -> String? {
        #if canImport(IOKit)
        // IOServiceGetMatchingService consumes the matching dict reference.
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        // Pull the whole property tree and string-scan it. This is the native
        // analogue of grepping `ioreg -rd1 -c IOPlatformExpertDevice` output.
        var propsRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        for (key, value) in props {
            if let hit = matchVMSignature(key) { return hit }
            if let s = value as? String, let hit = matchVMSignature(s) { return hit }
            if let data = value as? Data, let s = String(data: data, encoding: .utf8),
               let hit = matchVMSignature(s) {
                return hit
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    // MARK: Public IP — URLSession GET https://api.ipify.org

    /// Fetch the student's public IP. Mirrors getPublicIP() in student.js
    /// (api.ipify.org, ~8s budget). Returns nil on any failure so the caller
    /// can decide not to false-fail the network check.
    func fetchPublicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ip = raw, Self.looksLikeIPAddress(ip) else { return nil }
            return ip
        } catch {
            return nil
        }
    }

    /// Lightweight sanity check that the response is an IPv4/IPv6 literal and
    /// not an error page. Defence against ipify returning HTML on a captive
    /// portal. Accepts only hex digits, dots, and colons (same character class
    /// netdisp.js's detectNetworkPath used to validate teacherIp).
    private static func looksLikeIPAddress(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 45 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Must contain at least one dot (IPv4) or colon (IPv6).
        return s.contains(".") || s.contains(":")
    }

    // MARK: - TODO: features that need extra entitlements / frameworks
    //
    // The following are intentionally NOT implemented in this detection engine
    // because they require entitlements and/or ScreenCaptureKit that the plain
    // app target does not yet carry:
    //
    //   1. Camera / webcam capture (the optional require_webcam path). Needs the
    //      com.apple.security.device.camera entitlement and an AVCaptureSession,
    //      plus a usage-description in Info.plist. detectScreenRecordingPermission()
    //      above is the screen analogue; the camera grant would be checked with
    //      AVCaptureDevice.authorizationStatus(for: .video) once wired up.
    //
    //   2. Periodic screenshots during the exam (the capture-screen IPC). On
    //      macOS 14+ this should use ScreenCaptureKit (SCScreenshotManager /
    //      SCStream) gated behind CGRequestScreenCaptureAccess() — the legacy
    //      CGWindowListCreateImage path is deprecated. CGPreflightScreenCaptureAccess()
    //      above already reports whether that permission is in place; the actual
    //      frame grab is deferred to the capture wave.
    //
    // Both are read-for-the-teacher features layered on top of this engine; the
    // detection report is complete and useful without them.
}
