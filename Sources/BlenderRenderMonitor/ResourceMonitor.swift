import Darwin
import Foundation
import IOKit

struct ResourceUsage: Equatable {
    /// Share of the GPU's time spent on this process's work, like Activity Monitor's "% GPU".
    var gpuPercent: Double?
    /// Memory footprint, like Activity Monitor's "Memory" column. On Apple Silicon this includes GPU allocations.
    var memoryBytes: UInt64
    var peakMemoryBytes: UInt64
    /// Can exceed 100% when several cores are busy.
    var cpuPercent: Double?
}

/// Samples per-process GPU time, memory and CPU time, and turns the deltas into utilization.
@MainActor
final class ResourceMonitor {
    private struct Sample {
        let time: Double
        let gpuNanos: UInt64?
        let cpuNanos: UInt64
    }

    private var history: [pid_t: [Sample]] = [:]
    private static let window = 4
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample(pids: Set<pid_t>) -> [pid_t: ResourceUsage] {
        let now = Date().timeIntervalSince1970
        let gpu = Self.gpuTimeByPID()
        history = history.filter { pids.contains($0.key) }
        var result: [pid_t: ResourceUsage] = [:]
        for pid in pids {
            guard let rusage = Self.rusage(pid: pid) else { continue }
            let cpu = UInt64(Double(rusage.ri_user_time + rusage.ri_system_time) * Self.timebase)
            var samples = history[pid, default: []]
            samples.append(Sample(time: now, gpuNanos: gpu[pid], cpuNanos: cpu))
            samples = samples.suffix(Self.window)
            history[pid] = samples
            var usage = ResourceUsage(memoryBytes: rusage.ri_phys_footprint,
                                      peakMemoryBytes: rusage.ri_lifetime_max_phys_footprint)
            if let first = samples.first, let last = samples.last, last.time - first.time > 0.5 {
                let dt = (last.time - first.time) * 1e9
                usage.cpuPercent = Double(last.cpuNanos &- first.cpuNanos) / dt * 100
                if let a = first.gpuNanos, let b = last.gpuNanos, b >= a {
                    usage.gpuPercent = min(100, Double(b - a) / dt * 100)
                } else if last.gpuNanos == nil {
                    usage.gpuPercent = 0
                }
            }
            result[pid] = usage
        }
        return result
    }

    private static func rusage(pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info : nil
    }

    /// Total GPU time per process, from the GPU driver's user clients in the I/O Registry.
    private static func gpuTimeByPID() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators)
                == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS
            else { continue }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = creator.split(separator: ",").first?.split(separator: " ").last.flatMap({ pid_t($0) }),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                let nanos = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
                result[pid, default: 0] += nanos
            }
            IOObjectRelease(children)
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }
}
