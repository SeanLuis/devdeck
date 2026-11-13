import Darwin
import Foundation

public struct ProcessRecord: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let name: String
    public let executablePath: String
    public let args: [String]
    public let cwd: String?
    public let startTime: Date
    /// Physical footprint (what Activity Monitor calls "Memory").
    public let memoryBytes: UInt64
    public let cpuTimeNs: UInt64
    public let cpuPercent: Double
    public let isMine: Bool
    /// Pages actually in RAM right now.
    public let residentBytes: UInt64
    /// Bytes/s this process is faulting in from disk (swap or files).
    public let pageInRate: Double

    public var commandLine: String { args.isEmpty ? name : args.joined(separator: " ") }

    /// Estimate of this process' memory that lives compressed or in swap (footprint not resident in RAM).
    public var offloadedBytes: UInt64 { memoryBytes > residentBytes ? memoryBytes - residentBytes : 0 }

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, executablePath: String, args: [String],
                cwd: String?, startTime: Date, memoryBytes: UInt64, cpuTimeNs: UInt64, cpuPercent: Double, isMine: Bool,
                residentBytes: UInt64 = 0, pageInRate: Double = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name
        self.executablePath = executablePath; self.args = args; self.cwd = cwd; self.startTime = startTime
        self.memoryBytes = memoryBytes; self.cpuTimeNs = cpuTimeNs; self.cpuPercent = cpuPercent; self.isMine = isMine
        self.residentBytes = residentBytes; self.pageInRate = pageInRate
    }
}

public struct RawListeningPort: Sendable, Hashable {
    public let port: UInt16
    public let address: String
    public var isLoopback: Bool { address == "127.0.0.1" || address == "::1" }
}

/// Enumerates processes through libproc. Not thread-safe: owned by the `Sampler` actor.
final class ProcessScanner {
    private struct Key: Hashable { let pid: Int32; let start: UInt64 }

    private var argsCache: [Key: [String]] = [:]
    private var cwdCache: [Key: String] = [:]
    private var lastCPU: [Key: UInt64] = [:]
    private var lastPageIns: [Key: UInt64] = [:]
    private let pageSize = Double(sysconf(_SC_PAGESIZE))
    private var lastSampleNs: UInt64 = 0
    private var argBuffer: [UInt8]
    private let argMax: Int
    private let timebase: Double
    let myUID = getuid()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = Double(info.numer) / Double(max(info.denom, 1))
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        sysctl(&mib, 2, &argmax, &size, nil, 0)
        argMax = Int(max(argmax, 262_144))
        argBuffer = [UInt8](repeating: 0, count: argMax)
    }

    func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    func scan() -> [ProcessRecord] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSampleNs == 0 ? 0 : now &- lastSampleNs
        var newCPU: [Key: UInt64] = [:]
        var newPageIns: [Key: UInt64] = [:]
        var records: [ProcessRecord] = []
        records.reserveCapacity(800)

        for pid in allPids() {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            let key = Key(pid: pid, start: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec)
            let longName = Self.string(bsd.pbi_name)
            let name = longName.isEmpty ? Self.string(bsd.pbi_comm) : longName

            var pathBuf = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : ""

            var memory: UInt64 = 0
            var resident: UInt64 = 0
            var pageIns: UInt64 = 0
            var cpuTicks: UInt64 = 0
            var usage = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if rc == 0 {
                memory = usage.ri_phys_footprint
                resident = usage.ri_resident_size
                pageIns = usage.ri_pageins
                cpuTicks = usage.ri_user_time &+ usage.ri_system_time
            } else {
                var task = proc_taskinfo()
                let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                    memory = task.pti_resident_size
                    resident = task.pti_resident_size
                    pageIns = UInt64(max(0, task.pti_pageins))
                    cpuTicks = task.pti_total_user &+ task.pti_total_system
                }
            }
            let cpuNs = UInt64(Double(cpuTicks) * timebase)
            var cpuPercent = 0.0
            if elapsed > 0, let previous = lastCPU[key], cpuNs >= previous {
                cpuPercent = Double(cpuNs - previous) / Double(elapsed) * 100
            }
            newCPU[key] = cpuNs
            var pageInRate = 0.0
            if elapsed > 0, let previous = lastPageIns[key], pageIns >= previous {
                pageInRate = Double(pageIns - previous) * pageSize / (Double(elapsed) / 1_000_000_000)
            }
            newPageIns[key] = pageIns

            let mine = bsd.pbi_uid == myUID
            var args: [String] = []
            var cwd: String?
            if mine {
                if let cached = argsCache[key] {
                    args = cached
                } else {
                    args = readArgs(pid)?.args ?? []
                    argsCache[key] = args
                }
                if let cached = cwdCache[key] {
                    cwd = cached
                } else if let dir = readCwd(pid) {
                    cwd = dir
                    cwdCache[key] = dir
                }
            }

            records.append(ProcessRecord(
                pid: pid, ppid: Int32(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                executablePath: path, args: args, cwd: cwd,
                startTime: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000),
                memoryBytes: memory, cpuTimeNs: cpuNs, cpuPercent: cpuPercent, isMine: mine,
                residentBytes: resident, pageInRate: pageInRate
            ))
        }

        let alive = Set(newCPU.keys)
        argsCache = argsCache.filter { alive.contains($0.key) }
        cwdCache = cwdCache.filter { alive.contains($0.key) }
        lastCPU = newCPU
        lastPageIns = newPageIns
        lastSampleNs = now
        return records
    }

    /// argv and (optionally) the environment of a process, via KERN_PROCARGS2.
    func readArgs(_ pid: Int32, includeEnv: Bool = false) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        let rc = argBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard rc == 0, size > MemoryLayout<Int32>.size else { return nil }
        return argBuffer.withUnsafeBytes { raw -> (args: [String], env: [String]) in
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            var i = MemoryLayout<Int32>.size
            while i < size && raw[i] != 0 { i += 1 }   // exec path
            while i < size && raw[i] == 0 { i += 1 }   // padding
            var args: [String] = []
            var env: [String] = []
            var start = i
            while i < size {
                if raw[i] == 0 {
                    let value = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<i]), as: UTF8.self)
                    if args.count < argc {
                        args.append(value)
                    } else {
                        if value.isEmpty || !includeEnv { break }
                        env.append(value)
                    }
                    start = i + 1
                }
                i += 1
            }
            return (args, env)
        }
    }

    func readCwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = Self.string(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Listening TCP sockets owned by `pid`.
    func listeningPorts(pid: Int32) -> [RawListeningPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var result = Set<RawListeningPort>()
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize) == socketInfoSize else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            guard port != 0 else { continue }
            result.insert(RawListeningPort(port: port, address: Self.address(tcp.tcpsi_ini)))
        }
        return result.sorted { $0.port < $1.port }
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var addr = ini.insi_laddr.ina_6
            if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) == nil { return "::" }
            let s = String(cString: buffer)
            return s == "::" ? "*" : s
        }
        var addr = ini.insi_laddr.ina_46.i46a_addr4
        if inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) == nil { return "*" }
        let s = String(cString: buffer)
        return s == "0.0.0.0" ? "*" : s
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
