import AppKit
import Foundation

// 3.9.4 — AirDrop in the island.
// • Receiving: macOS publishes the progress of every file AirDrop writes into
//   Downloads (Finder draws its bar from the same object). The island shows
//   one banner with the combined percentage, then «Получено» with the file —
//   a tap shows it in Finder, and it also lands on the shelf.
// • A fallback for when no progress is published: a NEW file in Downloads
//   whose quarantine record names sharingd (the AirDrop daemon).
// • Sending: drop files on the right half of the shelf («AirDrop») — the
//   standard AirDrop picker opens with them.
final class AirDropReceiveWatch {
    var onProgress: ((_ fraction: Double, _ files: Int, _ name: String) -> Void)?
    var onReceived: ((_ urls: [URL]) -> Void)?

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private var subscriber: Any?
    private var active: [ObjectIdentifier: (progress: Progress, url: URL?, observation: NSKeyValueObservation)] = [:]
    private var finished: [URL] = []
    private var lastReport = Date.distantPast
    private var folderSource: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var announced = Set<String>()

    func start() {
        guard subscriber == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: Self.downloads) { [weak self] progress in
            DispatchQueue.main.async { self?.track(progress) }
            return { [weak self] in
                DispatchQueue.main.async { self?.untrack(progress) }
            }
        }
        startFolderFallback()
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        active.values.forEach { $0.observation.invalidate() }
        active.removeAll()
        finished.removeAll()
        folderSource?.cancel()
        folderSource = nil
    }

    // Only AirDrop: Safari and other downloads publish `.downloading`,
    // Finder copies `.copying`. 3.9.5: on this Mac (macOS 27) AirDrop
    // publishes WITHOUT a kind and without a file URL (seen in the log), so
    // a kind-less progress in Downloads counts as AirDrop too.
    static func isAirDrop(_ progress: Progress) -> Bool {
        guard let kind = progress.fileOperationKind else { return true }
        return kind == .receiving
    }

    private func track(_ progress: Progress) {
        LockIslandLog.record("airdrop: progress kind=\(progress.fileOperationKind?.rawValue ?? "nil") file=\(progress.fileURL?.lastPathComponent ?? "?") keys=\(progress.userInfo.keys.map(\.rawValue).sorted()) total=\(progress.totalUnitCount)")
        guard Self.isAirDrop(progress) else { return }
        let id = ObjectIdentifier(progress)
        guard active[id] == nil else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.report(force: false) }
        }
        active[id] = (progress, progress.fileURL, observation)
        report(force: true)
    }

    private func untrack(_ progress: Progress) {
        let id = ObjectIdentifier(progress)
        guard let entry = active.removeValue(forKey: id) else { return }
        entry.observation.invalidate()
        if !progress.isCancelled, let url = entry.url ?? progress.fileURL {
            finished.append(url)
        }
        if active.isEmpty {
            let urls = finished.filter { FileManager.default.fileExists(atPath: $0.path) }
            finished.removeAll()
            urls.forEach { announced.insert($0.standardizedFileURL.path) }
            if !urls.isEmpty {
                onReceived?(urls)
            } else if !progress.isCancelled {
                // No file URL in the progress: find the new AirDrop files now
                // (and once more a moment later, if macOS is still moving them).
                announceRecentFiles(retry: true)
            }
        } else {
            report(force: true)
        }
    }

    private func report(force: Bool) {
        guard !active.isEmpty else { return }
        // A few updates a second are plenty for a 34-pt bar.
        if !force && Date().timeIntervalSince(lastReport) < 0.25 { return }
        lastReport = Date()
        let values = active.values.map { min(1, max(0, $0.progress.fractionCompleted)) }
        let fraction = values.reduce(0, +) / Double(max(values.count, 1))
        let name = active.values.first?.url?.lastPathComponent ?? "AirDrop"
        onProgress?(fraction, active.count + finished.count, name)
    }

    // MARK: Fallback — a new AirDrop file appears in Downloads

    private func startFolderFallback() {
        let folder = Self.downloads
        known = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private func folderChanged() {
        let folder = Self.downloads
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let added = now.subtracting(known)
        known = now
        guard !added.isEmpty, active.isEmpty else { return }
        // 3.9.5: checked at once and again shortly after (the quarantine
        // record may be written a moment after the file) — no long wait.
        let urls = added.map { folder.appendingPathComponent($0) }
        announce(urls)
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.active.isEmpty else { return }
                self.announce(urls)
            }
        }
    }

    private func announce(_ candidates: [URL]) {
        let urls = candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter {
            !$0.lastPathComponent.hasPrefix(".") &&
            !announced.contains($0.standardizedFileURL.path) &&
            FileManager.default.fileExists(atPath: $0.path) &&
            Self.cameFromAirDrop($0)
        }
        urls.forEach { announced.insert($0.standardizedFileURL.path) }
        if !urls.isEmpty { onReceived?(urls) }
    }

    // AirDrop files in Downloads changed during the last two minutes.
    private func announceRecentFiles(retry: Bool) {
        let folder = Self.downloads
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let recent = names.map { folder.appendingPathComponent($0) }.filter { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey])
            let date = [values?.addedToDirectoryDate, values?.creationDate, values?.contentModificationDate]
                .compactMap { $0 }.max() ?? .distantPast
            return Date().timeIntervalSince(date) < 120
        }
        let before = announced.count
        announce(recent)
        if retry && announced.count == before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.announceRecentFiles(retry: false)
            }
        }
    }

    // Quarantine record: "flags;time;agent;uuid" — the agent is sharingd for AirDrop.
    static func cameFromAirDrop(_ url: URL) -> Bool {
        guard let value = quarantine(url) else { return false }
        return AirDropFormat.isAirDropQuarantine(value)
    }

    private static func quarantine(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(url.path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    static func icon(for urls: [URL]) -> NSImage? {
        guard let first = urls.first else { return nil }
        if urls.count == 1, let thumb = ScreenshotWatch.thumbnail(for: first) { return thumb }
        return NSWorkspace.shared.icon(forFile: first.path)
    }
}

// Opens the system AirDrop picker and reports whether the files were sent.
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropSender()
    var onSent: ((_ count: Int) -> Void)?

    @discardableResult
    func send(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: files) else { return false }
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let count = items.count
        DispatchQueue.main.async { self.onSent?(count) }
    }
}
