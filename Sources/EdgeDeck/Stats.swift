import Darwin
import Foundation
import IOKit

/// Samples system metrics once per second. All readings come from public
/// kernel/IOKit counters, so no elevated privileges are needed.
final class StatsSampler: ObservableObject {
    static let historyLength = 60

    @Published var cpu: Double = 0
    @Published var cpuCores: [Double] = []
    @Published var cpuHistory: [Double] = []

    @Published var gpu: Double?
    @Published var gpuHistory: [Double] = []

    @Published var memoryUsed: UInt64 = 0
    @Published var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var memoryHistory: [Double] = []

    @Published var diskUsed: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var diskRead: Double = 0
    @Published var diskWrite: Double = 0
    @Published var diskHistory: [Double] = []

    @Published var netIn: Double = 0
    @Published var netOut: Double = 0
    @Published var netInHistory: [Double] = []
    @Published var netOutHistory: [Double] = []

    private var timer: Timer?
    private var prevCPUTicks: [[UInt32]] = []
    private var prevDisk: (read: UInt64, write: UInt64, at: Date)?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var tick = 0

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        sampleCPU()
        if let g = Self.readGPU() {
            gpu = g
            push(&gpuHistory, g)
        }
        sampleMemory()
        sampleDiskIO()
        sampleNetwork()
        if tick % 30 == 0 { sampleDiskSpace() }
        tick += 1
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: CPU

    private func sampleCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [[UInt32]] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
            ])
        }

        if prevCPUTicks.count == ticks.count {
            var cores: [Double] = []
            var busyTotal = 0.0, allTotal = 0.0
            for (old, new) in zip(prevCPUTicks, ticks) {
                let busy = Double(new[0] &- old[0]) + Double(new[1] &- old[1]) + Double(new[2] &- old[2])
                let all = busy + Double(new[3] &- old[3])
                cores.append(all > 0 ? busy / all : 0)
                busyTotal += busy
                allTotal += all
            }
            cpuCores = cores
            cpu = allTotal > 0 ? busyTotal / allTotal : 0
            push(&cpuHistory, cpu)
        }
        prevCPUTicks = ticks
    }

    // MARK: GPU

    /// Apple Silicon (and most Intel/AMD drivers) publish utilisation on the IOAccelerator service.
    static func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let util = stats["Device Utilization %"] as? NSNumber else { continue }
            result = max(result ?? 0, util.doubleValue / 100)
        }
        return result
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        memoryUsed = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        push(&memoryHistory, Double(memoryUsed) / Double(max(memoryTotal, 1)))
    }

    // MARK: Disk

    private func sampleDiskSpace() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        diskTotal = Int64(total)
        diskUsed = Int64(total) - free
    }

    private func sampleDiskIO() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = Date()
        if let prev = prevDisk {
            let dt = max(now.timeIntervalSince(prev.at), 0.001)
            diskRead = read >= prev.read ? Double(read - prev.read) / dt : 0
            diskWrite = write >= prev.write ? Double(write - prev.write) / dt : 0
            push(&diskHistory, diskRead + diskWrite)
        }
        prevDisk = (read, write, now)
    }

    // MARK: Network

    /// Sums 64-bit byte counters of physical interfaces (en*), skipping loopback and
    /// tunnels so VPN traffic isn't counted twice.
    private func sampleNetwork() {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if msg.ifm_flags & IFF_LOOPBACK == 0,
                       if_indextoname(UInt32(msg.ifm_index), &name) != nil,
                       String(cString: name).hasPrefix("en") {
                        rx += msg.ifm_data.ifi_ibytes
                        tx += msg.ifm_data.ifi_obytes
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }

        let now = Date()
        if let prev = prevNet {
            let dt = max(now.timeIntervalSince(prev.at), 0.001)
            netIn = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
            netOut = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
            push(&netInHistory, netIn)
            push(&netOutHistory, netOut)
        }
        prevNet = (rx, tx, now)
    }
}

enum Format {
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1000, i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return v >= 100 || i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }

    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
}
