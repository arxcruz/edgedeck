import Darwin
import Foundation

struct ProcessUsage: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let memory: UInt64
}

/// Samples only while the CPU card's process face is on the current page.
@MainActor final class TopProcesses: ObservableObject {
    @Published private(set) var rows: [ProcessUsage] = []
    @Published private(set) var measuring = false

    private var task: Task<Void, Never>?
    private var session = UUID()

    func start() {
        stop()
        measuring = true
        let session = self.session
        task = Task.detached { [weak self] in
            guard !Task.isCancelled else { return }
            var previous = Self.snapshot()
            var previousTime = Date()
            // CPU time is a cumulative counter, so a second reading is needed.
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                let current = Self.snapshot()
                let now = Date()
                let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
                let rows = current.compactMap { pid, value -> ProcessUsage? in
                    guard let old = previous[pid], value.cpuTime >= old.cpuTime else { return nil }
                    // One fully occupied core is 100%, as in Activity Monitor.
                    let cpu = Double(value.cpuTime - old.cpuTime) / (elapsed * 1_000_000_000) * 100
                    return ProcessUsage(id: pid, name: value.name, cpu: cpu, memory: value.memory)
                }
                .sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
                await self?.receive(Array(rows.prefix(5)), session: session)
                previous = current
                previousTime = now
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session = UUID()
        rows = []
        measuring = false
    }

    private func receive(_ rows: [ProcessUsage], session: UUID) {
        guard self.session == session else { return }
        self.rows = rows
        measuring = false
    }

    private struct Reading {
        let name: String
        let cpuTime: UInt64
        let memory: UInt64
    }

    private nonisolated static func snapshot() -> [Int32: Reading] {
        guard !Task<Never, Never>.isCancelled else { return [:] }
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [:] }
        var readings: [Int32: Reading] = [:]
        for pid in pids.prefix(Int(count) / MemoryLayout<Int32>.stride) where pid > 0 {
            if Task<Never, Never>.isCancelled { break }
            var info = proc_taskinfo()
            let size = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
            guard size == MemoryLayout<proc_taskinfo>.size else { continue }
            var name = [CChar](repeating: 0, count: 256)
            let nameSize = name.withUnsafeMutableBufferPointer { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            let label = nameSize > 0 ? String(cString: name) : "PID \(pid)"
            readings[pid] = Reading(name: label, cpuTime: info.pti_total_user &+ info.pti_total_system,
                                    memory: info.pti_resident_size)
        }
        return readings
    }
}
