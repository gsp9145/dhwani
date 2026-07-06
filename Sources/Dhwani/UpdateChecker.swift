import AppKit

/// Background auto-updater. Checks GitHub for the latest release and installs
/// it silently once the app is idle. The request carries no identifiers and no
/// usage data — it fetches a version number, nothing more. Disable via
/// Settings → Automatic updates.
enum UpdateChecker {
    private static let apiURL = URL(string: "https://api.github.com/repos/gsp9145/dhwani/releases/latest")!
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static var timer: Timer?
    private static var isIdle: (() -> Bool)?
    private static var updateInFlight = false

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Call once at launch. First check runs shortly after startup, then every
    /// few hours for as long as the app lives.
    static func beginAutomaticChecks(whenIdle: @escaping () -> Bool) {
        isIdle = whenIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { checkNow() }
        let t = Timer(timeInterval: checkInterval, repeats: true) { _ in checkNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func checkNow() {
        guard Settings.shared.autoUpdate, !updateInFlight else { return }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isVersion(latest, newerThan: currentVersion) else { return }
            DispatchQueue.main.async { installWhenIdle(version: latest, attempts: 0) }
        }.resume()
    }

    /// Never restart the app mid-dictation — wait for a quiet moment.
    private static func installWhenIdle(version: String, attempts: Int) {
        guard Settings.shared.autoUpdate, !updateInFlight else { return }
        if isIdle?() ?? true {
            updateInFlight = true
            DebugLog.log("update: installing v\(version) over v\(currentVersion)")
            HUD.shared.show(.info("Updating Dhwani to \(version)…"))
            // The installer quits this instance mid-run; as a detached child
            // process it survives us and launches the new version.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "curl -fsSL https://gsp9145.github.io/dhwani/install.sh | bash"]
            try? process.run()
        } else if attempts < 24 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                installWhenIdle(version: version, attempts: attempts + 1)
            }
        }
    }

    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
