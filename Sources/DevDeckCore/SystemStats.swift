import Darwin
import Foundation

public struct SystemSample: Sendable, Codable, Hashable {
    public var time: Date
    public var memTotal: UInt64
    public var memUsed: UInt64
    public var memApp: UInt64
    public var memWired: UInt64
    public var memCompressed: UInt64
    public var memCached: UInt64
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level)
    public var pressure: Int
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var cpuPercent: Double
    public var diskFree: UInt64
    public var diskTotal: UInt64

    // Paging activity (bytes per second since the previous sample).
    public var swapInRate: Double = 0
    public var swapOutRate: Double = 0
    public var pageInRate: Double = 0
    public var compressRate: Double = 0
    public var decompressRate: Double = 0
    /// Uncompressed bytes held by the compressor ÷ physical bytes it uses (e.g. 3.2×).
    public var compressionRatio: Double = 0

    public var memPercent: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) * 100 }

    public var pressureLabel: String {
        switch pressure {
        case 4...: return "crítica"
        case 2...: return "alta"
        default: return "normal"
        }
    }

    public static let empty = SystemSample(time: Date(), memTotal: 0, memUsed: 0, memApp: 0, memWired: 0, memCompressed: 0,
                                           memCached: 0, pressure: 1, swapTotal: 0, swapUsed: 0, cpuPercent: 0, diskFree: 0, diskTotal: 0)
}

final class SystemStatsReader {
    private let host = mach_host_self()
    private let pageSize = UInt64(sysconf(_SC_PAGESIZE))
    private var lastTicks: [UInt64]?
    private var lastVM: [UInt64]?
    private var lastVMTime: Date?

    func read() -> SystemSample {
        var sample = SystemSample.empty
        sample.time = Date()

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        sample.memTotal = total

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let anonymous = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            sample.memApp = (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize
            sample.memWired = UInt64(vm.wire_count) * pageSize
            sample.memCompressed = UInt64(vm.compressor_page_count) * pageSize
            sample.memCached = (UInt64(vm.external_page_count) + purgeable) * pageSize
            sample.memUsed = min(total, sample.memApp + sample.memWired + sample.memCompressed)
            if vm.compressor_page_count > 0 {
                sample.compressionRatio = Double(vm.total_uncompressed_pages_in_compressor) / Double(vm.compressor_page_count)
            }

            let counters: [UInt64] = [UInt64(vm.swapins), UInt64(vm.swapouts), UInt64(vm.pageins),
                                      UInt64(vm.compressions), UInt64(vm.decompressions)]
            if let last = lastVM, let lastTime = lastVMTime {
                let dt = sample.time.timeIntervalSince(lastTime)
                if dt > 0.2 {
                    let rates = zip(counters, last).map { Double($0 >= $1 ? $0 - $1 : 0) * Double(pageSize) / dt }
                    sample.swapInRate = rates[0]
                    sample.swapOutRate = rates[1]
                    sample.pageInRate = rates[2]
                    sample.compressRate = rates[3]
                    sample.decompressRate = rates[4]
                }
            }
            lastVM = counters
            lastVMTime = sample.time
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        sample.pressure = Int(level)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            sample.swapTotal = swap.xsu_total
            sample.swapUsed = swap.xsu_used
        }

        var load = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let lr = withUnsafeMutablePointer(to: &load) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &loadCount) }
        }
        if lr == KERN_SUCCESS {
            let ticks = [UInt64(load.cpu_ticks.0), UInt64(load.cpu_ticks.1), UInt64(load.cpu_ticks.2), UInt64(load.cpu_ticks.3)]
            if let last = lastTicks {
                let d = zip(ticks, last).map { $0 &- $1 }
                let busy = Double(d[0] + d[1] + d[3])
                let all = busy + Double(d[2])
                sample.cpuPercent = all > 0 ? busy / all * 100 : 0
            }
            lastTicks = ticks
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            sample.diskFree = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            sample.diskTotal = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        }
        return sample
    }
}
