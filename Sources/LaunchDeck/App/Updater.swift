import AppKit

/// Self-updater backed by GitHub Releases. Checks the latest release of the repo,
/// and when its tag (e.g. `v1.2.0`) is newer than this build it can download the
/// attached `.zip`, swap the app bundle in place and relaunch.
///
/// Publishing a version: bump CFBundleShortVersionString, then run
/// `scripts/release.sh`, which builds, zips and creates the GitHub release.
final class Updater {
    static let shared = Updater()
    static let repository = "fancyecho/LaunchDeck"

    struct Release {
        let version: String
        let notes: String
        let asset: URL
        let page: URL
    }

    /// Set once a check finds something newer than the running build.
    private(set) var available: Release?
    private(set) var isInstalling = false
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Quiet check now and then once a day.
    func start() {
        check { _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in }
        }
    }

    /// Fetches the latest release; `completion` runs on the main queue with the
    /// newer release, or nil when up to date (or the check failed).
    func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                result = .success(nil)  // no releases published yet
            } else if let data, let release = Self.parse(data) {
                result = .success(Self.isVersion(release.version, newerThan: self.currentVersion) ? release : nil)
            } else {
                result = .failure(UpdateError.badResponse)
            }
            DispatchQueue.main.async {
                if case .success(let release) = result { self.available = release }
                completion(result)
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let asset = (zip["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", asset: asset, page: page)
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case badResponse, noApp, wrongApp, unzipFailed

        var errorDescription: String? {
            switch self {
            case .badResponse: L10n.t("GitHub returned an unexpected response.", "GitHub 返回了无法识别的内容。")
            case .noApp: L10n.t("The download didn't contain an app.", "下载的文件里没有找到应用。")
            case .wrongApp: L10n.t("The download isn't LaunchDeck.", "下载的应用不是 LaunchDeck。")
            case .unzipFailed: L10n.t("Couldn't unpack the download.", "无法解压下载的文件。")
            }
        }
    }

    /// Downloads, unpacks and swaps in the new bundle, then relaunches. Calls
    /// `failure` on the main queue if anything goes wrong; on success the app quits.
    func install(_ release: Release, failure: @escaping (Error) -> Void) {
        guard !isInstalling else { return }
        isInstalling = true
        URLSession.shared.downloadTask(with: release.asset) { file, _, error in
            do {
                if let error { throw error }
                guard let file else { throw UpdateError.badResponse }
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("LaunchDeckUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try fm.moveItem(at: file, to: zip)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("extracted").path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw UpdateError.unzipFailed }

                let extracted = work.appendingPathComponent("extracted")
                guard let app = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" })
                else { throw UpdateError.noApp }
                guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }

                // Swap bundles; the running process keeps working off the old files.
                let target = Bundle.main.bundleURL
                _ = try fm.replaceItemAt(target, withItemAt: app)

                DispatchQueue.main.async { Self.relaunch(target) }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    failure(error)
                }
            }
        }.resume()
    }

    private static func relaunch(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - UI

    /// Alert asking to install `release`; shown above the launcher window.
    func promptToInstall(_ release: Release, above window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L10n.t("LaunchDeck \(release.version) is available", "LaunchDeck \(release.version) 已发布")
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = L10n.t("You have \(currentVersion).", "当前版本 \(currentVersion)。")
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: L10n.t("Update and Relaunch", "更新并重启"))
        alert.addButton(withTitle: L10n.t("Later", "稍后"))
        alert.addButton(withTitle: L10n.t("View on GitHub", "在 GitHub 查看"))
        raise(alert, above: window)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release) { error in
                let failed = NSAlert(error: error)
                failed.messageText = L10n.t("Update failed", "更新失败")
                failed.informativeText = error.localizedDescription
                Updater.shared.raise(failed, above: window)
                failed.runModal()
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    /// Manual "Check for Updates…": always reports back.
    func checkInteractively(above window: NSWindow?) {
        check { result in
            switch result {
            case .success(let release?):
                self.promptToInstall(release, above: window)
            case .success(nil):
                let alert = NSAlert()
                alert.messageText = L10n.t("You're up to date", "已是最新版本")
                alert.informativeText = L10n.t("LaunchDeck \(self.currentVersion) is the latest version.",
                                               "LaunchDeck \(self.currentVersion) 是目前的最新版本。")
                self.raise(alert, above: window)
                alert.runModal()
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = L10n.t("Couldn't check for updates", "检查更新失败")
                alert.informativeText = error.localizedDescription
                self.raise(alert, above: window)
                alert.runModal()
            }
        }
    }

    fileprivate func raise(_ alert: NSAlert, above window: NSWindow?) {
        alert.window.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? NSWindow.Level.normal.rawValue) + 1)
    }
}
