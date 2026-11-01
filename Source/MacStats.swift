import Foundation
import IOKit

// 3.12.0 — data for the new lock-screen widgets.

// Battery of Bluetooth accessories (Magic Mouse, Keyboard, Trackpad and
// other HID devices that report it). Read from the IOKit registry — no
// permission and no Bluetooth scanning; only devices already connected.
enum AccessoryBatteryReader {
    static func read() -> [AccessoryBattery] {
        var found: [AccessoryBattery] = []
        for className in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
                var unmanaged: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                      let percent = (properties["BatteryPercent"] as? NSNumber)?.intValue else { continue }
                let name = (properties["Product"] as? String) ?? (properties["DeviceName"] as? String) ?? "Устройство"
                found.append(AccessoryBattery(name: name, percent: percent))
            }
        }
        return AccessoryBattery.cleaned(found)
    }
}

// CPU (between two readings) and memory in use, like Activity Monitor.
final class SystemLoadSampler {
    private var previous: (busy: UInt64, total: UInt64)?

    func sample() -> SystemLoad {
        SystemLoad(cpu: cpuUsage(), memory: memoryUsage())
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previous = (busy, total) }
        if let previous, total > previous.total {
            return SystemLoad.fraction(busy: busy &- previous.busy, total: total &- previous.total)
        }
        return SystemLoad.fraction(busy: busy, total: total)   // since boot, first time only
    }

    private func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return SystemLoad.fraction(busy: used, total: ProcessInfo.processInfo.physicalMemory)
    }
}
