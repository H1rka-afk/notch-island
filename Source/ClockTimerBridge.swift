import AppKit
import ApplicationServices
import Foundation

// Experimental read-only sync with the actual Clock.app timer UI.
// Clock does not publish a supported timer-state API to other macOS apps.
// Accessibility is only used with the user's permission; no passwords,
// screen recording, or private Clock databases are touched.
struct ObservedClockTimer {
    let remaining: TimeInterval
    let paused: Bool
}

final class ClockTimerBridge {
    var onSnapshot: ((ObservedClockTimer?) -> Void)?
    var onStatus: ((String) -> Void)?
    private var pollTimer: Timer?
    private let worker = DispatchQueue(label: "app.notchisland.clock.bridge", qos: .utility)
    private var busy = false
    private var misses = 0
    // Only confirmed observations become the source of interpolation.
    // Short AX failures never delete a timer that macOS previously confirmed.
    private var lastConfirmed: (snapshot: ObservedClockTimer, received: Date)?
    private var lastDeepAutoScan = Date.distantPast
    private var lastSystemBarScan = Date.distantPast
    private var cachedSystemBarTimer: (timer: ObservedClockTimer, received: Date)?
    private let systemBarScanInterval: TimeInterval = 18
    private var pauseButton: AXUIElement?
    private var pauseButtonKind: ClockTimerControlPolicy.Button = .unknown
    private var cancelButton: AXUIElement?
    private var lastKnownPaused: Bool?
    // These are set only by an actual Clock scan (never by cached menu-bar
    // interpolation) and reported back to the main queue with the snapshot.
    private var lastScanHasPlaybackEvidence = false
    private var lastScanConfirmedNoTimer = false
    private var lastScanClockReadable = false

    // Commands are serialized on the main queue and kept pending until Clock
    // actually confirms the result, or a bounded verification period expires.
    private enum PendingCommand {
        case toggle(expectedPaused: Bool, expires: Date)
        case cancel(expires: Date, missingChecks: Int)
    }
    private var pendingCommand: PendingCommand?
    private var commandBusy = false
    private var forceDeepNext = false

    func start() {
        pollTimer?.invalidate()
        // Use the same actual Clock field extraction for automatic and manual
        // polling; only logging differs. The old 80-node automatic scan missed
        // timers found by the 300-node "Check timer" diagnostic.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        pollTimer?.tolerance = 0.8
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private var diagnoseNext = false
    func refreshNow(diagnostics: Bool = false, forceFullScan: Bool = false) {
        if forceFullScan { forceDeepNext = true }
        if diagnostics {
            diagnoseNext = true
            lastDiagnostic = "Часы: выполняется углублённая проверка…"
            onStatus?(lastDiagnostic)
        }
        refresh()
    }

    private func clockApp() -> NSRunningApplication? {
        // Clock's bundle identifier is not exposed as a stable integration
        // contract across macOS releases. Resolve both known identifiers and
        // the actual system app path rather than assume one string.
        NSWorkspace.shared.runningApplications.first { app in
            let id = app.bundleIdentifier ?? ""
            if id == "com.apple.clock" || id == "com.apple.mobiletimer" { return true }
            if app.bundleURL?.lastPathComponent == "Clock.app" &&
                app.bundleURL?.path.hasPrefix("/System/Applications/") == true { return true }
            let name = (app.localizedName ?? "").lowercased()
            return name == "clock" || name == "часы"
        }
    }

    func openClock() {
        let path = "/System/Applications/Clock.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        // Clock chooses its own selected tab. The Timers tab can be selected
        // inside Clock. Never create a separate in-app imitation of its timer.
    }

    // Explicit permission request. AXIsProcessTrusted() checks the CURRENT
    // signed executable, not the visible checkbox associated with an older
    // ad-hoc-signed build of the same bundle identifier.
    func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let authorized = AXIsProcessTrustedWithOptions(options)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        let alert = NSAlert()
        alert.messageText = authorized ? "Универсальный доступ разрешён" : "Доступ для текущей версии не подтверждён"
        alert.informativeText = authorized
            ? "Notch Island уже имеет доступ. Запусти таймер в приложении «Часы» и нажми «Проверить таймер»."
            : "Открой «Универсальный доступ», выключи и снова включи Notch Island. Если запись уже включена, но проверка по-прежнему отрицательная, запусти отдельный файл «Восстановить доступ к таймеру.command» из установщика и выдай доступ заново. После изменения разрешения полностью выйди из Notch Island и открой его из папки «Программы». Это необходимо после обновлений с временной подписью."
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
        if authorized { refreshNow(diagnostics: true) }
    }

    private var lastDiagnostic = "Часы: проверка таймера…"
    var statusLine: String { lastDiagnostic }

    func togglePause() { press(cancel: false) }
    func cancel() { press(cancel: true) }

    private func press(cancel: Bool) {
        // Do not allow a double click to invert the real Clock timer while an
        // earlier command is still being delivered or verified.
        guard !commandBusy, pendingCommand == nil else {
            lastDiagnostic = "Часы: ожидается подтверждение предыдущей команды"
            onStatus?(lastDiagnostic)
            return
        }
        commandBusy = true
        worker.async { [weak self] in
            guard let self else { return }
            // Use the last confirmed AX button first. A fresh *full* tree
            // scan used to block every click for hundreds of remote IPC calls.
            // On a stale button, fall back to one new full scan.
            var kind = self.pauseButtonKind
            let cachedButton = cancel ? self.cancelButton : self.pauseButton
            let cachedValid = cancel || kind == .pause || kind == .resume
            var success = cachedValid && cachedButton.map {
                AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
            } == true
            if !success {
                let snapshot = self.captureTimer(detailedScan: true)
                kind = self.pauseButtonKind
                let currentButton = cancel ? self.cancelButton : self.pauseButton
                let currentValid = cancel || (snapshot != nil &&
                    (kind == .pause || kind == .resume))
                success = currentValid && currentButton.map {
                    AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
                } == true
            }
            if success {
                // A menu-bar snapshot from before the action must not
                // reinstate a canceled or paused timer during confirmation.
                self.cachedSystemBarTimer = nil
                self.lastSystemBarScan = .distantPast
            }
            let targetPaused = kind == .pause
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.commandBusy = false
                if success {
                    if cancel {
                        self.pendingCommand = .cancel(
                            expires: Date().addingTimeInterval(5.5), missingChecks: 0)
                        // The real Clock app accepted AXPress. Retire the
                        // satellite visually now, instead of leaving a black
                        // badge waiting for two slow AX polling intervals.
                        // Reconcile with Clock if verification subsequently
                        // discovers that cancellation did not take effect.
                        self.onSnapshot?(nil)
                        self.lastDiagnostic = "Часы: отмена отправлена; проверяю результат"
                    } else {
                        self.pendingCommand = .toggle(
                            expectedPaused: targetPaused, expires: Date().addingTimeInterval(5.5))
                        self.lastDiagnostic = "Часы: команда \(targetPaused ? "паузы" : "продолжения") отправлена; проверяю состояние"
                    }
                    self.onStatus?(self.lastDiagnostic)
                    // AXPress success is not proof of a successful pause or
                    // cancellation. Keep the last real snapshot visible.
                    for delay in [0.20, 0.85, 1.55, 3.0, 5.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.pendingCommand != nil else { return }
                            self.refreshNow(forceFullScan: true)
                        }
                    }
                } else {
                    self.lastDiagnostic = cancel
                        ? "Часы: не найдена доступная кнопка отмены работающего таймера"
                        : "Часы: не удалось определить кнопку паузы/продолжения"
                    self.onStatus?(self.lastDiagnostic)
                    let alert = NSAlert()
                    alert.messageText = "Не удалось управлять системным таймером"
                    alert.informativeText = "macOS не предоставила подтверждённую кнопку \(cancel ? "отмены" : "паузы/продолжения") для обнаруженного таймера. Notch Island не изменил собственный отсчёт. Открой приложение «Часы» для управления."
                    alert.addButton(withTitle: "Открыть «Часы»")
                    alert.addButton(withTitle: "Отмена")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { self.openClock() }
                }
            }
        }
    }

    private func refresh() {
        guard !busy else { return }
        busy = true
        let logging = diagnoseNext
        let deep = logging || forceDeepNext
        forceDeepNext = false
        worker.async { [weak self] in
            guard let self else { return }
            let result = self.captureTimer(detailedScan: deep)
            let reason = self.scanReason
            let details = self.scanDetails
            let playbackEvidence = self.lastScanHasPlaybackEvidence
            let confirmedNoTimer = self.lastScanConfirmedNoTimer
            let readableClock = self.lastScanClockReadable
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if logging {
                    self.diagnoseNext = false
                    self.writeDiagnostics(status: reason, details: details,
                                          snapshot: result)
                }
                var commandStatus: String?
                if let pending = self.pendingCommand {
                    switch pending {
                    case .toggle(let expected, let deadline):
                        if ClockTimerControlPolicy.confirmsToggle(
                            expectedPaused: expected, observedPaused: result?.paused,
                            hasEvidence: playbackEvidence) {
                            self.pendingCommand = nil
                            commandStatus = expected
                                ? "Часы: пауза подтверждена системой"
                                : "Часы: продолжение подтверждено системой"
                        } else if Date() >= deadline {
                            self.pendingCommand = nil
                            commandStatus = "Часы: команда отправлена, но изменение состояния не подтверждено"
                        }
                    case .cancel(let deadline, let misses):
                        // A canceled timer can leave an idle 05:00 preset in
                        // Clock. An AX tree with nodes but no active timer
                        // is valid post-cancel evidence even with presets.
                        if result == nil && (confirmedNoTimer || readableClock) {
                            if ClockTimerControlPolicy.confirmsCancel(
                                missingChecks: misses + 1,
                                reliableMissing: confirmedNoTimer || readableClock) {
                                self.pendingCommand = nil
                                self.lastConfirmed = nil
                                self.misses = 0
                                self.lastDiagnostic = "Часы: отмена таймера подтверждена"
                                self.onSnapshot?(nil)
                                self.onStatus?(self.lastDiagnostic)
                                return
                            }
                            self.pendingCommand = .cancel(expires: deadline, missingChecks: 1)
                        } else if result != nil {
                            // An actual countdown is still visible. We cannot
                            // declare cancellation just because AXPress succeeded.
                            self.pendingCommand = .cancel(expires: deadline, missingChecks: 0)
                        }
                        if Date() >= deadline {
                            self.pendingCommand = nil
                            if result == nil {
                                // Clock accepted the cancellation and subsequent
                                // observations contain no active countdown.
                                // A closed/unreadable Clock window cannot prove
                                // success; clear stale display state without
                                // reporting a false positive confirmation.
                                self.lastConfirmed = nil
                                self.misses = 0
                                self.lastDiagnostic = "Часы: отсчёт больше не обнаружен после отмены"
                                self.onSnapshot?(nil)
                                self.onStatus?(self.lastDiagnostic)
                                return
                            }
                            commandStatus = "Часы: отмена не подтверждена; проверь системные «Часы»"
                        }
                    }
                }
                // AXPress was accepted and the satellite is waiting for
                // verification. Do not resurrect it from a stale snapshot.
                if case .cancel = self.pendingCommand {
                    self.onStatus?(commandStatus ?? self.lastDiagnostic)
                    return
                }
                // Two full, readable Clock scans with no timer-specific
                // countdown or controls are stronger evidence than a cached
                // observation. Never let an old, stopped timer hang forever.
                if confirmedNoTimer {
                    self.reliableNoTimerReads += 1
                } else {
                    self.reliableNoTimerReads = 0
                }
                if result == nil && self.reliableNoTimerReads >= 2 &&
                   self.pendingCommand == nil {
                    self.lastConfirmed = nil
                    self.misses = 0
                    self.lastDiagnostic = "Часы: активный таймер не обнаружен"
                    self.onSnapshot?(nil)
                    self.onStatus?(self.lastDiagnostic)
                    return
                }
                if let result {
                    self.reliableNoTimerReads = 0
                    self.misses = 0
                    self.lastConfirmed = (result, Date())
                    self.lastDiagnostic = commandStatus ?? ("Часы: найден таймер · " +
                        (result.paused ? "пауза" : "идёт отсчёт"))
                    self.onSnapshot?(result)
                } else {
                    self.misses += 1
                    self.lastDiagnostic = commandStatus ?? "Часы: " + reason
                    // Missing AX data is not evidence of pause or cancellation.
                    // Preserve only the last actually observed timer state.
                    if let last = self.lastConfirmed {
                        let age = Date().timeIntervalSince(last.received)
                        let remaining = TimerObservationContinuity.remaining(
                            last: last.snapshot.remaining, paused: last.snapshot.paused,
                            secondsSinceObservation: age)
                        if TimerObservationContinuity.shouldRetain(
                            last: last.snapshot.remaining, paused: last.snapshot.paused,
                            secondsSinceObservation: age) {
                            if commandStatus == nil {
                                self.lastDiagnostic = "Часы: связь временно потеряна, показывается последний подтверждённый отсчёт"
                            }
                            self.onSnapshot?(ObservedClockTimer(
                                remaining: remaining, paused: last.snapshot.paused))
                        } else {
                            self.lastConfirmed = nil
                            self.onSnapshot?(nil)
                        }
                    } else if self.misses >= 3 {
                        self.onSnapshot?(nil)
                    }
                }
                self.onStatus?(self.lastDiagnostic)
                if self.diagnoseNext && !logging { self.refresh() }
                else if self.forceDeepNext { self.refresh() }
            }
        }
    }

    // Written only on the serial AX queue; read on the main queue after the
    // scan has completed. No macOS timer database or private API is used.
    private var scanReason = "нет доступных данных"
    private var scanDetails = "сканирование ещё не выполнялось"
    // Keep samples from individual menu-bar hosts separate. A static timer
    // preset in Clock must never validate a Control Center label.
    private struct BarSample {
        let path: [Int]
        let seconds: TimeInterval
        let at: Date
    }
    private var lastBarSamples: [String: BarSample] = [:]
    // A Clock window may contain saved presets, a live countdown and other
    // time values simultaneously. Remember ALL time-labelled AX positions,
    // not just the highest-scoring static preset.
    private struct CountdownSample {
        let path: [Int]
        let seconds: TimeInterval
        let at: Date
    }
    private var lastClockSamples: [CountdownSample] = []
    private var lastObservedTimerPath: [Int]?
    // Only a measured, decreasing Clock field establishes an active timer.
    // Once verified, an explicit, nearby Resume button can keep a paused timer
    // visible, but an idle preset such as 05:00 cannot create a timer.
    private var verifiedClockPath: [Int]?
    private var reliableNoTimerReads = 0

    private func writeDiagnostics(status: String, details: String,
                                  snapshot: ObservedClockTimer?) {
        // Record structural diagnostics, not the user's named timer or any
        // other menu-bar text. Created only when the user presses Check.
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("NotchIsland-ClockTimer.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  status=\(status); " +
            "\(details); " +
            "result=\(snapshot.map { "\(Int($0.remaining))s paused=\($0.paused)" } ?? "none")\n"
        if let bytes = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(bytes)
                handle.closeFile()
            } else {
                try? bytes.write(to: url, options: .atomic)
            }
        }
    }

    private struct Node {
        let element: AXUIElement
        let path: [Int]
        let label: String
        let role: String
    }

    // Sibling digits are only considered in Clock.app, never in generic
    // SystemUIServer/menu text. We still require running-timer evidence
    // (pause control or a decrement in the next observation).
    private func withDigitSiblingCandidates(_ nodes: [Node]) -> [Node] {
        var groups: [[Int]: [Node]] = [:]
        for node in nodes where !node.path.isEmpty {
            groups[Array(node.path.dropLast()), default: []].append(node)
        }
        var derived: [Node] = []
        for (parent, siblings) in groups where siblings.count >= 2 && siblings.count <= 5 {
            let sorted = siblings.sorted { ($0.path.last ?? 0) < ($1.path.last ?? 0) }
            guard let seconds = ClockTimerTextParser.remainingFromDigitSiblings(sorted.map(\.label)),
                  seconds > 0 else { continue }
            let time = sorted.map(\.label).filter { $0 != ":" }.joined(separator: ":")
            if let first = sorted.first {
                derived.append(Node(element: first.element, path: parent + [0],
                                    label: time, role: "AXStaticText"))
            }
        }
        return nodes + derived
    }

    private func captureTimer(detailedScan: Bool) -> ObservedClockTimer? {
        lastScanHasPlaybackEvidence = false
        lastScanConfirmedNoTimer = false
        lastScanClockReadable = false
        let basicTrust = AXIsProcessTrusted()
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let refreshedTrust = AXIsProcessTrustedWithOptions([optionKey: false] as CFDictionary)
        guard refreshedTrust else {
            scanReason = "macOS не доверяет текущей сборке; повторно выдай Универсальный доступ и перезапусти"
            // Record the running app's identity. A stale permission grant may
            // refer to a previous ad-hoc-signed build with the same display name.
            scanDetails = "AXIsProcessTrusted=\(basicTrust), rechecked=\(refreshedTrust), " +
                "bundle=\(Bundle.main.bundleIdentifier ?? "unknown"), " +
                "app=\(Bundle.main.bundleURL.path), pid=\(ProcessInfo.processInfo.processIdentifier)"
            pauseButton = nil; pauseButtonKind = .unknown; cancelButton = nil
            return nil
        }

        pauseButton = nil
        pauseButtonKind = .unknown
        cancelButton = nil
        let clock = clockApp()
        // A full Clock scan is expensive (hundreds of cross-process AX calls).
        // Keep periodic deep scans for automatic discovery, but use a small
        // quick scan in between. Manual Check always gets a complete scan.
        let deepScan = detailedScan ||
            Date().timeIntervalSince(lastDeepAutoScan) >= 24
        if deepScan { lastDeepAutoScan = Date() }
        let nodeLimit = deepScan ? 300 : 125
        let depthLimit = deepScan ? 12 : 9
        var clockReason = "«Часы» не запущены"
        if let clock {
            let scanStarted = Date()
            let root = AXUIElementCreateApplication(clock.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.22)
            var nodes: [Node] = []
            // Some Clock builds expose their timer as AXChildren rather than
            // AXWindows; collect both instead of making them exclusive.
            let windows = children(root, key: kAXWindowsAttribute as CFString)
            let content = children(root, key: kAXChildrenAttribute as CFString)
            let roots = windows + content
            for (index, item) in roots.enumerated() {
                walk(item, path: [index], depth: 0,
                     maxNodes: nodeLimit, maxDepth: depthLimit,
                     diagnostics: deepScan, into: &nodes)
                if nodes.count >= nodeLimit { break }
            }
            let enriched = withDigitSiblingCandidates(nodes)
            lastScanClockReadable = roots.count > 0 && nodes.count >= 4
            let duration = Int(Date().timeIntervalSince(scanStarted) * 1000)
            scanDetails = "Clock pid=\(clock.processIdentifier), windows=\(windows.count), roots=\(roots.count), nodes=\(nodes.count), digitGroups=\(enriched.count - nodes.count), AXscan=\(duration)ms, detailed=\(detailedScan), deep=\(deepScan)"
            if let found = extractTimer(from: enriched, source: "Clock", allowUnlabelled: true) {
                cachedSystemBarTimer = nil
                scanReason = "таймер обнаружен через «Часы»"
                return found
            }
            // Only a complete, readable Clock tree is meaningful negative
            // evidence after Cancel. An empty tree must never clear the UI.
            lastScanConfirmedNoTimer = deepScan && nodes.count >= 4 && roots.count > 0 &&
                !enriched.contains(where: { node in
                    let action = ClockTimerControlPolicy.button(for: node.label)
                    let text = node.label.lowercased()
                    return action == .pause || action == .resume ||
                        (ClockTimerTextParser.remaining(in: node.label) != nil &&
                         (text.contains("timer") || text.contains("таймер") ||
                          text.contains("remaining") || text.contains("осталось")))
                })
            clockReason = nodes.isEmpty
                ? "нет дерева Accessibility окна «Часов» (проверь, что окно открыто)"
                : "отсчёт не подтверждён: неподвижное время может быть шаблоном таймера"
        } else {
            scanDetails = "Clock not running"
            lastClockSamples = []
            lastObservedTimerPath = nil
            verifiedClockPath = nil
            lastKnownPaused = nil
        }

        // macOS can keep a real Clock timer running when Clock's UI is closed.
        // Its system menu-bar timer is sometimes exposed by Control Centre.
        // Read it when available; never infer a duration from presence alone.
        // Walking Control Center's entire Accessibility tree is expensive on
        // some Macs. Only rescan it periodically, or on an explicit check.
        // Keep using the Clock window on every pass when it is available.
        let shouldScanSystemBar = detailedScan ||
            Date().timeIntervalSince(lastSystemBarScan) >= systemBarScanInterval
        if !shouldScanSystemBar {
            // A confirmed countdown from the system menu remains valid
            // between slower scans. Interpolate from that observation rather
            // than emitting three false "not found" events in 12 seconds.
            if let cached = cachedSystemBarTimer {
                let age = Date().timeIntervalSince(cached.received)
                let remaining = cached.timer.remaining - (cached.timer.paused ? 0 : age)
                if age < systemBarScanInterval + 5 && remaining > 0 {
                    scanReason = "таймер через системную строку меню (между опросами)"
                    return ObservedClockTimer(remaining: remaining, paused: cached.timer.paused)
                }
            }
            scanReason = clockReason + "; резервный поиск в строке меню выполняется раз в 18 секунд"
            return nil
        }
        lastSystemBarScan = Date()
        let controlHosts = NSWorkspace.shared.runningApplications.filter { app in
            let id = (app.bundleIdentifier ?? "").lowercased()
            return id == "com.apple.controlcenter" || id == "com.apple.systemuiserver"
        }
        if controlHosts.isEmpty { scanDetails += "; menu bar hosts not found" }
        for centre in controlHosts {
            let root = AXUIElementCreateApplication(centre.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.18)
            var nodes: [Node] = []
            let menu = children(root, key: kAXMenuBarAttribute as CFString)
            let extras = children(root, key: "AXExtrasMenuBar" as CFString)
            let content = children(root, key: kAXChildrenAttribute as CFString)
            let roots = menu + extras + content
            for (index, item) in roots.enumerated() {
                walk(item, path: [index], depth: 0,
                     maxNodes: detailedScan ? 160 : 45,
                     maxDepth: detailedScan ? 10 : 6,
                     diagnostics: detailedScan, into: &nodes)
                if nodes.count >= (detailedScan ? 160 : 45) { break }
            }
            scanDetails += "; menu host=\(centre.bundleIdentifier ?? "?"), roots=\(roots.count), nodes=\(nodes.count)"
            if let found = extractTimer(
                from: nodes, source: "ControlCentre:\(centre.bundleIdentifier ?? "unknown")",
                allowUnlabelled: false) {
                cachedSystemBarTimer = (found, Date())
                scanReason = "таймер обнаружен в системной строке меню"
                return found
            }
        }
        cachedSystemBarTimer = nil
        scanReason = clockReason + "; проверь «Часы» → «Таймеры» и разрешение «Универсальный доступ»"
        return nil
    }

    private func extractTimer(from nodes: [Node], source: String,
                              allowUnlabelled: Bool) -> ObservedClockTimer? {
        guard !nodes.isEmpty else { return nil }
        let timerWords = ["timer", "таймер", "countdown", "обратный отсчёт"]
        let remainingWords = ["remaining", "time left", "осталось", "остающееся время"]
        let controls = nodes.filter { node in
            let kind = ClockTimerControlPolicy.button(for: node.label)
            return (kind == .pause || kind == .resume) &&
                (node.role.lowercased().contains("button") ||
                 node.role.lowercased().contains("control"))
        }
        struct Candidate {
            let seconds: TimeInterval
            let path: [Int]
            let control: Node?
            let score: Int
            let confirmed: Bool
        }
        var candidates: [Candidate] = []
        let now = Date()
        let previousClockSamples = lastClockSamples
        let isClock = source == "Clock"
        let isSystemBar = source.hasPrefix("ControlCentre:")
        var newClockSamples: [CountdownSample] = []
        var verifiedDecrements = 0
        for node in nodes {
            guard let seconds = ClockTimerTextParser.remaining(in: node.label),
                  seconds > 0 else { continue }
            let label = node.label.lowercased()
            let labelledTimer = timerWords.contains(where: { label.contains($0) })
            let labelledRemaining = remainingWords.contains(where: { label.contains($0) })
            // Timer status item and countdown must be in the same small AX
            // subtree, not somewhere else in Control Centre (system clock).
            let nearTimer = nodes.contains { other in
                timerWords.contains(where: { other.label.lowercased().contains($0) }) &&
                (sharedPrefix(other.path, node.path) >= max(1, min(other.path.count, node.path.count) - 2))
            }
            let nearbyControl = controls.max { left, right in
                sharedPrefix(left.path, node.path) < sharedPrefix(right.path, node.path)
            }
            let common = nearbyControl.map { sharedPrefix($0.path, node.path) } ?? 0
            let confirmedControl = common >= 1 && isClock
            // Compare values at the SAME AX element position across scans.
            // Otherwise a fixed "05:00" preset and a fixed "04:50" preset
            // could be mistaken for one countdown. A decreasing value in
            // Clock itself is sufficient evidence of a running timer even
            // when macOS does not label the countdown element "Timer".
            let previous = lastBarSamples[source]
            let observedTick: Bool
            if isClock {
                observedTick = previousClockSamples.contains { sample in
                    return sample.path == node.path &&
                           ClockTimerTextParser.isDecreasingCountdown(
                               previous: sample.seconds, current: seconds,
                               elapsed: now.timeIntervalSince(sample.at))
                }
                newClockSamples.append(CountdownSample(path: node.path, seconds: seconds, at: now))
                if observedTick { verifiedDecrements += 1 }
            } else {
                observedTick = previous.map {
                    $0.path == node.path && ClockTimerTextParser.isDecreasingCountdown(
                        previous: $0.seconds, current: seconds,
                        elapsed: now.timeIntervalSince($0.at))
                } ?? false
            }
            // A menu-bar item without a timer-specific label is a clock,
            // not evidence of an Apple Clock countdown. Do not fake it.
            if isSystemBar && !(labelledTimer || (nearTimer && labelledRemaining)) {
                continue
            }
            if !allowUnlabelled && !labelledTimer && !labelledRemaining { continue }
            // Do not use a label, static duration, or a nearby unrelated
            // playback button as proof of an active timer. Require a measured
            // countdown first; afterwards only an explicitly associated Clock
            // pause/resume control may continue the verified timer.
            let action = nearbyControl.map {
                ClockTimerControlPolicy.button(for: $0.label)
            } ?? .unknown
            let associatedControl = confirmedControl &&
                (common >= 2 || (common >= 1 && labelledRemaining)) &&
                (action == .pause || action == .resume)
            let sameVerifiedClock = isClock && verifiedClockPath == node.path
            let confirmed = ClockTimerControlPolicy.acceptsTimerObservation(
                decremented: observedTick,
                previouslyVerifiedSameField: sameVerifiedClock,
                associatedControl: associatedControl,
                action: action)
            let score = (confirmedControl ? 80 : 0) + (labelledRemaining ? 70 : 0) +
                (labelledTimer ? 55 : 0) + (nearTimer ? 16 : 0) +
                (observedTick ? 35 : 0) + common * 4 +
                (isClock && lastObservedTimerPath == node.path ? 26 : 0)
            candidates.append(Candidate(seconds: seconds, path: node.path,
                                        control: associatedControl ? nearbyControl : nil,
                                        score: score, confirmed: confirmed))
        }
        if isClock { lastClockSamples = Array(newClockSamples.prefix(80)) }
        let timerNodeCount = nodes.filter { node in
            timerWords.contains(where: { node.label.lowercased().contains($0) })
        }.count
        let timeNodeCount = nodes.filter { ClockTimerTextParser.remaining(in: $0.label) != nil }.count
        let hint = timerNodeCount > 0 && timeNodeCount == 0 ? ", timer labels exist but no readable countdown" : ""
        scanDetails += "; \(source) timerLabels=\(timerNodeCount), timeLabels=\(timeNodeCount), controls=\(controls.count), candidates=\(candidates.count), decreasing=\(verifiedDecrements)\(hint)"
        // Clock can expose an unlabelled HH:MM:SS control. Let the second
        // observation demonstrate it is actively counting down instead of
        // falsely reporting a saved 5-minute preset as a running timer.
        if isSystemBar, let candidate = candidates.max(by: { $0.score < $1.score }) {
            lastBarSamples[source] = BarSample(
                path: candidate.path, seconds: candidate.seconds, at: now)
        }
        guard let best = candidates.filter({ $0.confirmed }).max(by: {
            $0.score == $1.score ? $0.seconds > $1.seconds : $0.score < $1.score
        }) else { return nil }
        // A timer may be confirmed by decrementing values while its controls
        // occupy a sibling AX group. Match the nearest actionable button,
        // rather than discard the controls whenever the time node lacks a
        // direct button parent. With only one Clock timer, a sole button is
        // unambiguous even when AX paths have disjoint roots.
        func closest(_ options: [Node]) -> Node? {
            guard !options.isEmpty else { return nil }
            let sorted = options.sorted {
                sharedPrefix($0.path, best.path) > sharedPrefix($1.path, best.path)
            }
            guard let first = sorted.first else { return nil }
            return sharedPrefix(first.path, best.path) > 0 || options.count == 1
                ? first : nil
        }
        let pauseControl = best.control ?? closest(controls)
        let cancelControls = nodes.filter { node in
            (node.role.lowercased().contains("button") ||
             node.role.lowercased().contains("control")) &&
                ClockTimerControlPolicy.button(for: node.label) == .cancel
        }
        let kind = pauseControl.map { ClockTimerControlPolicy.button(for: $0.label) } ?? .unknown
        pauseButton = pauseControl?.element
        pauseButtonKind = kind
        cancelButton = closest(cancelControls)?.element
        // The actual Clock action is authoritative. Previously, missing
        // resume controls were interpreted as "running", even when paused.
        let previousSample = previousClockSamples.first(where: { $0.path == best.path })
        let ticked = isClock ? (previousSample.map {
            ClockTimerTextParser.isDecreasingCountdown(
                previous: $0.seconds, current: best.seconds,
                elapsed: now.timeIntervalSince($0.at))
        } ?? false) : true // Verified menu-bar candidates also demonstrated a decrement.
        let stalled = isClock && (previousSample.map {
            now.timeIntervalSince($0.at) >= 3.5 &&
            now.timeIntervalSince($0.at) < 42 &&
            abs($0.seconds - best.seconds) <= 1.0
        } ?? false)
        let paused = ClockTimerControlPolicy.observedPaused(
            button: kind, ticked: ticked,
            stalled: isClock && verifiedClockPath == best.path && stalled,
            previous: isClock && verifiedClockPath == best.path
                ? lastKnownPaused : nil) ?? false
        lastKnownPaused = paused
        lastObservedTimerPath = best.path
        if isClock { verifiedClockPath = best.path }
        lastScanHasPlaybackEvidence = (kind == .pause || kind == .resume) ||
            ticked || (stalled && lastObservedTimerPath == best.path)
        scanDetails += "; chosenControl=\(kind), cancelAvailable=\(cancelButton != nil), stateEvidence=\(lastScanHasPlaybackEvidence)"
        return ObservedClockTimer(remaining: best.seconds, paused: paused)
    }

    private func sharedPrefix(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).prefix(while: { pair in pair.0 == pair.1 }).count
    }

    private func walk(_ element: AXUIElement, path: [Int], depth: Int,
                      maxNodes: Int, maxDepth: Int, diagnostics: Bool,
                      into output: inout [Node]) {
        guard depth < maxDepth && output.count < maxNodes else { return }
        AXUIElementSetMessagingTimeout(element, diagnostics ? 0.18 : 0.09)
        // Lightweight polling reads two values per AX node. Role, description
        // and identifier are only needed when the user requests a diagnostic
        // scan; hundreds of synchronous remote IPC calls caused noticeable
        // lag even on a background queue.
        let fields: [String] = diagnostics
            ? [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, "AXIdentifier", "AXHelp"]
            : [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
        let labels = fields.compactMap { string(element, key: $0 as CFString) }
        let likelyControl = labels.contains { text in
            let normalized = text.lowercased()
            return normalized.contains("pause") || normalized.contains("resume") ||
                   normalized.contains("пауза") || normalized.contains("возобнов") ||
                   normalized.contains("продолж") || normalized.contains("приостанов") ||
                   normalized.contains("отмен") || normalized.contains("остановить") ||
                   normalized.contains("сброс") || normalized.contains("cancel") ||
                   normalized.contains("stop")
        }
        let role = diagnostics || likelyControl
            ? (string(element, key: kAXRoleAttribute as CFString) ?? "") : ""
        output.append(Node(element: element, path: path,
                           label: labels.joined(separator: " "), role: role))
        let ordinary = children(element, key: kAXChildrenAttribute as CFString)
        let visible = ordinary.isEmpty ? children(element, key: "AXVisibleChildren" as CFString) : ordinary
        for (i, child) in visible.enumerated() {
            walk(child, path: path + [i], depth: depth + 1,
                 maxNodes: maxNodes, maxDepth: maxDepth,
                 diagnostics: diagnostics, into: &output)
            if output.count >= maxNodes { break }
        }
    }

    private func children(_ element: AXUIElement, key: CFString) -> [AXUIElement] {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &result) == .success else { return [] }
        if let array = result as? [AXUIElement] { return array }
        // kAXMenuBarAttribute, unlike kAXWindowsAttribute, is one element.
        // A conditional cast to an opaque CF type does not check its runtime type
        // and is rejected by Swift on macOS. Validate its CFTypeID explicitly.
        if let single = result, CFGetTypeID(single) == AXUIElementGetTypeID() {
            return [single as! AXUIElement]
        }
        return []
    }

    private func string(_ element: AXUIElement, key: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }


}
