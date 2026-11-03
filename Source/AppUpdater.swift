import AppKit
import Darwin
import Foundation

// One-click update from the user's Downloads folder.
// 1. Watches ~/Downloads (names only) for a Ovira release newer than
//    the running version.
// 2. On request: unpacks it into a private temporary folder, verifies the
//    bundled Info.plist (same bundle id AND the expected version), clears the
//    download quarantine on that private copy only, and runs the SAME
//    installer in the background. The installer rebuilds, replaces
//    /Applications/Ovira.app and reopens it. Progress goes to
//    ~/Library/Logs/NotchIsland-Update.log.
// Nothing is downloaded from the network; only files the user already has.
final class AppUpdater {
    struct Candidate: Equatable {
        let version: String
        let url: URL
        let isArchive: Bool
    }

    enum State: Equatable {
        case idle
        case available(Candidate)
        case installing(String)
        case failed(String)
    }

    var onChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.notchisland.updater", qos: .utility)
    private var scanning = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    // 3.21.0: ready-made releases from GitHub are downloaded here by the app
    // itself; the folder is scanned exactly like «Загрузки».
    static var cacheFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NotchIsland/Updates", isDirectory: true)
    }

    // 4.6.2: ready builds live in the public «notch-island-releases»
    // repository (the source code repository becomes private). The old
    // address stays as a fallback; the newer of the two wins.
    static let releasesAPIs = [
        URL(string: "https://api.github.com/repos/H1rka-afk/notch-island-releases/releases/latest")!,
        URL(string: "https://api.github.com/repos/H1rka-afk/notch-island/releases/latest")!
    ]
    static let githubKey = "githubUpdatesV400"
    static var githubEnabled: Bool { (UserDefaults.standard.object(forKey: githubKey) as? Bool) ?? true }
    private var lastGitHubCheck = Date.distantPast
    private var githubTimer: Timer?
    private var downloading = false
    private(set) var githubStatus = ""

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchIsland-Update.log")
    }

    var statusLine: String {
        switch state {
        case .idle:
            return downloading ? "Скачиваю новую версию с GitHub…"
                : "Установлена версия \(Self.currentVersion) — она последняя."
        case .available(let candidate):
            return "Готова версия \(candidate.version). Установлена \(Self.currentVersion)."
        case .installing(let version):
            return "Устанавливаю \(version)… Несколько секунд — приложение перезапустится само."
        case .failed(let reason):
            return "Не удалось обновить: \(reason)"
        }
    }

    var availableCandidate: Candidate? {
        if case .available(let candidate) = state { return candidate }
        return nil
    }

    func start() {
        guard timer == nil else { return }
        scan()
        // Listing one folder's names every 20 s is negligible work.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.scan() }
        timer.tolerance = 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 3.21.0: GitHub — shortly after launch, then every 3 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkGitHub() }
        let remote = Timer(timeInterval: 3 * 3600, repeats: true) { [weak self] _ in self?.checkGitHub() }
        remote.tolerance = 600
        RunLoop.main.add(remote, forMode: .common)
        githubTimer = remote
    }

    // MARK: GitHub releases (3.21.0)

    // Looks at the latest release; a newer one is downloaded into the cache
    // folder in the background, then offered like an archive in «Загрузки».
    func checkGitHub(force: Bool = false) {
        guard Self.githubEnabled, !downloading else { return }
        if case .installing = state { return }
        if !force && Date().timeIntervalSince(lastGitHubCheck) < 10 * 60 { return }
        lastGitHubCheck = Date()
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [UpdatePolicy.GitHubRelease] = []
        for url in Self.releasesAPIs {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("NotchIsland/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            group.enter()
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let data, status == 200, let release = UpdatePolicy.githubRelease(from: data) {
                    lock.lock(); found.append(release); lock.unlock()
                    group.leave()
                    return
                }
                Self.log("github: api \(status) for \(url.pathComponents.dropFirst(2).prefix(2).joined(separator: "/")) — trying the release page")
                // 4.10.1: the API allows 60 requests an hour; the release
                // page has no such limit.
                let repo = url.pathComponents.dropFirst(2).prefix(2).joined(separator: "/")
                guard let page = URL(string: "https://github.com/\(repo)/releases/latest") else { group.leave(); return }
                var pageRequest = URLRequest(url: page, timeoutInterval: 20)
                pageRequest.httpMethod = "HEAD"
                pageRequest.setValue("NotchIsland/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                URLSession.shared.dataTask(with: pageRequest) { _, pageResponse, _ in
                    defer { group.leave() }
                    guard let final = pageResponse?.url,
                          let release = UpdatePolicy.githubRelease(fromTagURL: final, repo: repo) else { return }
                    lock.lock(); found.append(release); lock.unlock()
                }.resume()
            }.resume()
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            let newest = found.max { UpdatePolicy.isNewer($1.version, than: $0.version) }
            guard let release = newest else {
                Self.log("github: no release information")
                return
            }
            guard UpdatePolicy.isNewer(release.version, than: Self.currentVersion) else { return }
            let target = Self.cacheFolder.appendingPathComponent(release.assetName)
            if FileManager.default.fileExists(atPath: target.path) {
                DispatchQueue.main.async { self.scan() }
                return
            }
            DispatchQueue.main.async { self.download(release, to: target) }
        }
    }

    private func download(_ release: UpdatePolicy.GitHubRelease, to target: URL) {
        downloading = true
        onChange?(state)
        Self.log("github: downloading \(release.assetName)")
        URLSession.shared.downloadTask(with: release.assetURL) { [weak self] temporary, response, _ in
            let fm = FileManager.default
            var ok = false
            if let temporary, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? fm.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
                // Older downloads are not needed any more.
                for old in (try? fm.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: old)
                }
                ok = (try? fm.moveItem(at: temporary, to: target)) != nil
            }
            Self.log(ok ? "github: downloaded \(release.assetName)" : "github: download failed")
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloading = false
                self.onChange?(self.state)
                self.scan()
            }
        }.resume()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        if case .installing = state { return }
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            let found = Self.findCandidate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if case .installing = self.state { return }
                if let found {
                    self.state = .available(found)
                } else if case .available = self.state {
                    self.state = .idle
                } else if case .idle = self.state {
                    // unchanged
                }
                // A failure message stays until a new release appears.
            }
        }
    }

    private static func findCandidate() -> Candidate? {
        // 3.21.0: the GitHub download cache and «Загрузки»; the newest wins.
        var best: Candidate?
        for folder in [cacheFolder, downloadsFolder] {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            let entries = urls.map { url -> (name: String, isDirectory: Bool) in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return (url.lastPathComponent, isDirectory)
            }
            guard let found = UpdatePolicy.newest(in: entries, current: currentVersion) else { continue }
            if let current = best, !UpdatePolicy.isNewer(found.release.version, than: current.version) { continue }
            best = Candidate(version: found.release.version,
                             url: folder.appendingPathComponent(found.name),
                             isArchive: found.release.isArchive)
        }
        return best
    }

    func install(_ candidate: Candidate) {
        if case .installing = state { return }
        state = .installing(candidate.version)
        queue.async { [weak self] in
            let result = Self.prepareAndLaunch(candidate)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = result {
                    Self.log("FAILED: \(error)")
                    self.state = .failed(error)
                }
                // On success the installer quits this process and opens the
                // new version; the "installing" state remains until then.
            }
        }
    }

    // Returns an error message, or nil once the installer has been launched.
    private static func prepareAndLaunch(_ candidate: Candidate) -> String? {
        let fm = FileManager.default
        log("update \(currentVersion) → \(candidate.version) from \(candidate.url.lastPathComponent)")
        let work = fm.temporaryDirectory.appendingPathComponent("notch-island-update-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
        catch { return "не удалось создать временную папку" }

        // Private copy: the user's file in Downloads is never modified.
        let copyArgs = candidate.isArchive
            ? ["-x", "-k", candidate.url.path, work.path]
            : [candidate.url.path, work.appendingPathComponent(candidate.url.lastPathComponent).path]
        guard run("/usr/bin/ditto", copyArgs) == 0 else {
            return candidate.isArchive ? "архив повреждён или не распаковывается" : "не удалось скопировать папку"
        }

        guard let installer = findInstaller(in: work) else {
            return "в архиве нет «\(UpdatePolicy.installerName)»"
        }
        let root = installer.deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Source/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              plist["CFBundleIdentifier"] as? String == UpdatePolicy.bundleIdentifier else {
            return "архив не похож на Ovira (нет Source/Info.plist с нужным идентификатором)"
        }
        let packaged = plist["CFBundleShortVersionString"] as? String ?? ""
        guard packaged == candidate.version else {
            return "версия внутри архива (\(packaged)) не совпадает с названием (\(candidate.version))"
        }

        // Only this private temporary copy is un-quarantined and made executable.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", work.path])
        for script in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where script.pathExtension == "command" {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        // The installer quits this app with killall. When an app exits,
        // launchd also terminates every process left in the app's PROCESS
        // GROUP — 3.1.13/3.1.14 lost the installer right before it reopened
        // the new version. Spawn it in a NEW process group so it outlives us.
        // Output goes to a file, never to a pipe owned by this process.
        guard let pid = spawnDetached(["/bin/bash", "-c", "cd \"$1\" && NOTCH_ISLAND_QUIET=1 exec /bin/bash \"$2\"",
                                       "notch-island-update", root.path, installer.path],
                                      logPath: logURL.path) else {
            return "не удалось запустить установщик"
        }
        log("installer started in its own process group (pid \(pid))")
        return nil
    }

    // Quits and reopens Ovira (e.g. after granting a permission that
    // macOS applies only to a fresh process). The helper lives in its own
    // process group so it survives this app's exit.
    static func relaunch() {
        let appPath = Bundle.main.bundlePath
        guard spawnDetached(["/bin/bash", "-c",
                             // Same launchd fallback as the installer (3.4.2).
                             """
                             sleep 1; /usr/bin/open "$1"
                             for i in $(seq 1 8); do /bin/ps -axo comm= | /usr/bin/grep -qE '(^|/)NotchIsland$' && exit 0; sleep 0.5; done
                             L=local.notchisland.relaunch
                             /bin/launchctl remove "$L" 2>/dev/null
                             /bin/launchctl submit -l "$L" -- /bin/sh -c '/usr/bin/open "$0"; exec /bin/sleep 600' "$1"
                             for i in $(seq 1 20); do /bin/ps -axo comm= | /usr/bin/grep -qE '(^|/)NotchIsland$' && break; sleep 0.5; done
                             /bin/launchctl remove "$L" 2>/dev/null
                             """, "notch-island-relaunch", appPath],
                            logPath: "/dev/null") != nil else { return }
        NSApp.terminate(nil)
    }

    static func spawnDetached(_ arguments: [String], logPath: String) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environ)
        return status == 0 ? pid : nil
    }

    private static func findInstaller(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            if UpdatePolicy.isInstaller(url.lastPathComponent) { return url }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func openLogForAppending() -> FileHandle? {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    static func log(_ message: String) {
        guard let handle = openLogForAppending() else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}
