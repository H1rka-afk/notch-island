import AppKit
import Foundation

// Watches the macOS Focus database (read-only) and reports ON/OFF/mode
// switches. Files are read on a utility queue; callbacks arrive on main.
// The very first reading is a silent baseline: launching Ovira while
// "Do Not Disturb" is already on never produces a banner.
final class FocusModeMonitor {
    enum Access: Equatable {
        case unknown
        case granted
        case denied      // ~/Library/DoNotDisturb is protected by TCC (Full Disk Access)
        case noDatabase  // Focus has never been configured on this Mac
    }

    private enum Reading {
        case mode(FocusMode?)
        case denied
        case noDatabase
        case transient   // half-written file; keep the previous state
    }

    var onChange: ((_ mode: FocusMode?, _ previous: FocusMode?) -> Void)?
    var onStatus: (() -> Void)?
    private(set) var current: FocusMode?
    private(set) var access: Access = .unknown
    private(set) var isRunning = false

    private var hasBaseline = false
    private var timer: Timer?
    private var readInFlight = false
    private var deniedSkips = 0
    private var generation = UUID()
    private let queue = DispatchQueue(label: "app.notchisland.focus", qos: .utility)
    // Touched only on `queue`.
    private var configurationStamp: Date?
    private var configurationData: Data?

    static var databaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hasBaseline = false
        deniedSkips = 0
        generation = UUID()
        poll()
        // Half a second keeps the banner close to the Control Center click.
        // Only a small JSON file is read; the large configuration file is
        // re-read only when its modification date changes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in PerformanceMonitor.measure("focus") { self?.poll() } }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        hasBaseline = false
        generation = UUID()
        readInFlight = false
        current = nil
        access = .unknown
        onStatus?()
    }

    // Used by the settings window: re-check immediately, including after the
    // user has just granted Full Disk Access.
    func refreshNow() {
        guard isRunning else { return }
        deniedSkips = 0
        poll()
    }

    var statusLine: String {
        guard isRunning else { return "Показ фокусирования выключен." }
        switch access {
        case .unknown:
            return "Проверка состояния фокусирования…"
        case .denied:
            return "Нет доступа к состоянию фокусирования. Добавь Ovira в «Полный доступ к диску» и перезапусти приложение."
        case .noDatabase:
            return "Режимы фокусирования на этом Mac ещё не использовались."
        case .granted:
            guard let current else { return "Доступ есть. Сейчас фокусирование выключено." }
            return "Доступ есть. Сейчас включено: «\(current.name)»" +
                (current.scheduled ? " (по расписанию)." : ".")
        }
    }

    private func poll() {
        guard isRunning, !readInFlight else { return }
        // Without permission, do not hammer the protected folder twice a
        // second (each attempt is logged by macOS). Retry every ~5 s.
        if access == .denied && deniedSkips > 0 {
            deniedSkips -= 1
            return
        }
        readInFlight = true
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            let reading = self.readDatabase()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.readInFlight = false
                self.apply(reading)
            }
        }
    }

    private func apply(_ reading: Reading) {
        switch reading {
        case .transient:
            return
        case .denied:
            deniedSkips = 9
            let changed = access != .denied
            access = .denied
            // When access appears later, take a fresh silent baseline.
            hasBaseline = false
            current = nil
            if changed { onStatus?() }
        case .noDatabase:
            settle(nil, access: .noDatabase)
        case .mode(let mode):
            settle(mode, access: .granted)
        }
    }

    private func settle(_ mode: FocusMode?, access newAccess: Access) {
        let accessChanged = access != newAccess
        access = newAccess
        guard hasBaseline else {
            hasBaseline = true
            current = mode
            onStatus?()
            return
        }
        let previous = current
        current = mode
        if previous?.identifier != mode?.identifier {
            onStatus?()
            onChange?(mode, previous)
        } else if accessChanged || previous != mode {
            // Same mode; only its name, symbol or schedule flag changed.
            onStatus?()
        }
    }

    // Runs on `queue`.
    private func readDatabase() -> Reading {
        let directory = Self.databaseDirectory
        let assertionsURL = directory.appendingPathComponent("Assertions.json")
        let configurationURL = directory.appendingPathComponent("ModeConfigurations.json")

        var assertions: Data?
        do {
            assertions = try Data(contentsOf: assertionsURL)
        } catch {
            if !Self.isMissingFile(error) { return .denied }
        }
        if let assertions, !assertions.isEmpty,
           !FocusDatabaseParser.isWellFormed(assertions) {
            return .transient
        }

        var stamp: Date?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: configurationURL.path)
            stamp = attributes[.modificationDate] as? Date
        } catch {
            if !Self.isMissingFile(error) { return .denied }
        }
        if stamp == nil {
            configurationData = nil
            configurationStamp = nil
        } else if stamp != configurationStamp || configurationData == nil {
            if let fresh = try? Data(contentsOf: configurationURL),
               FocusDatabaseParser.isWellFormed(fresh) {
                configurationData = fresh
                configurationStamp = stamp
            } else if configurationData == nil {
                // Neither a cached nor a complete new copy: try next tick.
                return .transient
            }
        }

        if assertions == nil && configurationData == nil {
            return .noDatabase
        }
        return .mode(FocusDatabaseParser.activeMode(assertionsJSON: assertions,
                                                    configurationsJSON: configurationData))
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }
}

extension FocusMode {
    // Custom modes may use symbols that do not exist on older macOS builds.
    var displaySymbol: String {
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil { return symbol }
        if let fallback = FocusDatabaseParser.builtIns[identifier]?.symbol,
           NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            return fallback
        }
        return "moon.fill"
    }

    static var demo: FocusMode {
        FocusDatabaseParser.describe(FocusDatabaseParser.defaultIdentifier,
                                     configuration: nil, scheduled: false)
    }
}
