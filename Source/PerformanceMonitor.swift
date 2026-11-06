import Foundation
import Darwin

// 3.10.2 — finds what makes Ovira slow, on the user's own Mac.
// • A watchdog on a background thread pings the main thread every 50 ms.
//   When the main thread answers late (> 80 ms = visible hitch), the stall
//   and the operation that was running are written to the log.
// • Instrumented operations (`measure`) slower than 12 ms are logged.
// • Every 30 s: the app's CPU use since the last line.
// Log: ~/Library/Logs/NotchIsland-Performance.log (kept under 400 KB).
// Nothing leaves the Mac.
// 3.16.4 — «Энергосбережение»: fewer frames for the waveform and no living
// backgrounds. Off, on battery only (default), or always.
enum EnergySaver {
    static let modeKey = "energySaverModeV3164"
    static var onBattery = false
    static var mode: String { UserDefaults.standard.string(forKey: modeKey) ?? "battery" }
    static var isActive: Bool { mode == "always" || (mode == "battery" && onBattery) }
}

enum PerformanceMonitor {
    private static let lock = NSLock()
    private static var currentOperation = "idle"
    // 3.16.4: main-thread time per operation over the last 30 s.
    private static var totals: [String: (ms: Double, calls: Int)] = [:]
    private static var started = false
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchIsland-Performance.log")
    private static let writer = DispatchQueue(label: "app.notchisland.perf.log", qos: .utility)

    static func start() {
        guard !started else { return }
        started = true
        write("— start, version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        let thread = Thread { watchdog() }
        thread.name = "NotchIsland.perf.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    // Runs `work` on the current (main) thread, naming it for the watchdog.
    @discardableResult
    static func measure<T>(_ name: String, _ work: () -> T) -> T {
        lock.lock(); let previous = currentOperation; currentOperation = name; lock.unlock()
        let begin = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
        lock.lock()
        currentOperation = previous
        let old = totals[name] ?? (0, 0)
        totals[name] = (old.ms + ms, old.calls + 1)
        lock.unlock()
        if ms > 12 { write(String(format: "slow %@: %.0f ms", name, ms)) }
        return result
    }

    // Counts an event (a view redraw, a published change) without timing it.
    static func count(_ name: String) {
        lock.lock()
        let old = totals[name] ?? (0, 0)
        totals[name] = (old.ms, old.calls + 1)
        lock.unlock()
    }

    // 4.13.0: while the island animates, even short main-thread hiccups
    // (a dropped frame or two) are written down with what was running —
    // they are what makes a spring look jerky.
    private static var animationUntil: UInt64 = 0
    private static var animationName = ""

    static func animating(_ name: String, for seconds: Double = 0.7) {
        let until = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        lock.lock()
        if until > animationUntil { animationUntil = until; animationName = name }
        lock.unlock()
    }

    private static func currentAnimation() -> String? {
        lock.lock(); defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds < animationUntil ? animationName : nil
    }

    private static func operation() -> String {
        lock.lock(); defer { lock.unlock() }
        return currentOperation
    }

    private static func watchdog() {
        var lastCPU = cpuSeconds()
        var lastCPUAt = Date()
        while true {
            let sent = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            var reported = false
            var seenOperation = "idle"
            while answered.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
                let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                if waited > 80 && !reported {
                    seenOperation = operation()
                    reported = true
                }
            }
            let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            let animation = currentAnimation()
            if waited > 80 {
                write(String(format: "STALL main thread %.0f ms (during: %@)%@", waited, seenOperation,
                             animation.map { " in animation: \($0)" } ?? ""))
            } else if let animation, waited > 30 {
                write(String(format: "hitch %.0f ms in animation: %@ (during: %@)", waited, animation, operation()))
            }
            if Date().timeIntervalSince(lastCPUAt) >= 30 {
                let now = cpuSeconds()
                let percent = (now - lastCPU) / Date().timeIntervalSince(lastCPUAt) * 100
                write(String(format: "cpu %.1f%% (last 30 s)", percent) + threadBreakdown() + operationsBreakdown())
                lastCPU = now
                lastCPUAt = Date()
            }
            // 3.16.3: 4 checks a second are enough to catch stalls; during
            // an animation every frame is watched.
            Thread.sleep(forTimeInterval: currentAnimation() == nil ? 0.25 : 0.012)
        }
    }

    // «ops: wave 410 ms ×900, volume 35 ms ×120» — then the counters restart.
    private static func operationsBreakdown() -> String {
        lock.lock()
        let snapshot = totals
        totals = [:]
        lock.unlock()
        let top = snapshot.sorted {
            $0.value.ms != $1.value.ms ? $0.value.ms > $1.value.ms : $0.value.calls > $1.value.calls
        }.prefix(9)
        guard !top.isEmpty else { return "" }
        return " | ops: " + top.map { String(format: "%@ %.0f ms ×%d", $0.key, $0.value.ms, $0.value.calls) }
            .joined(separator: ", ")
    }

    // The busiest threads right now: «main 7%, audio 3%».
    private static func threadBreakdown() -> String {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return "" }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        var rows: [(String, Double)] = []
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            guard status == KERN_SUCCESS, info.flags & Int32(TH_FLAGS_IDLE) == 0 else { continue }
            let percent = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            guard percent >= 0.5 else { continue }
            var name = "thread \(i)"
            if i == 0 { name = "main" }
            else if let pthread = pthread_from_mach_thread_np(list[i]) {
                var buffer = [CChar](repeating: 0, count: 64)
                if pthread_getname_np(pthread, &buffer, buffer.count) == 0, buffer[0] != 0 {
                    name = String(cString: buffer)
                }
            }
            rows.append((name, percent))
        }
        let top = rows.sorted { $0.1 > $1.1 }.prefix(4)
        guard !top.isEmpty else { return "" }
        return " — " + top.map { String(format: "%@ %.0f%%", $0.0, $0.1) }.joined(separator: ", ")
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        writer.async {
            guard let data = line.data(using: .utf8) else { return }
            let path = url.path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 400_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: path), let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
