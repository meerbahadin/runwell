import Foundation
import Darwin

/// Section 5.2. Enumerates processes and captures cumulative counters.
///
/// Section 4.2: collectors return raw snapshots with timestamps and availability.
/// They do not calculate rates — that is MetricEngine's job, because a rate needs
/// two samples and a validated interval.
///
/// Appendix F: never shell out to `ps`, `top` or `powermetrics` in the sampling loop.
/// Everything here is a direct libproc call.
public struct ProcessCollector: Sendable {
    public init() {}

    /// One collection cycle's worth of raw readings.
    public struct Capture: Sendable {
        public let snapshots: [RawProcessSnapshot]
        public let rawIdentities: [ProcessKey: RawIdentity]
        /// Section 5.2: permission failures are represented per process, and the
        /// count feeds the coverage figure the Overview must show (Section 3.1).
        public let inaccessibleCount: Int
        public let capturedAt: MonotonicInstant
    }

    /// Identity fields available straight from the kernel, before NSWorkspace and
    /// bundle resolution turn them into an application group.
    public struct RawIdentity: Sendable {
        public let pid: pid_t
        public let parentPID: pid_t
        public let userID: uid_t
        public let name: String
        public let executablePath: String?
    }

    public func capture() -> Capture {
        let capturedAt = MonotonicInstant.now()
        let pids = Self.listPIDs()

        var snapshots: [RawProcessSnapshot] = []
        var identities: [ProcessKey: RawIdentity] = [:]
        var inaccessible = 0
        snapshots.reserveCapacity(pids.count)

        for pid in pids {
            guard pid > 0 else { continue }
            // The start time is half of the identity, so a process whose bsdinfo we
            // cannot read has no trustworthy key and is counted as inaccessible.
            guard let bsd = Self.bsdInfo(pid) else {
                inaccessible += 1
                continue
            }
            let key = ProcessKey(pid: pid, startAbsoluteTime: Self.startAbsoluteTime(bsd))

            identities[key] = RawIdentity(
                pid: pid,
                parentPID: pid_t(bitPattern: bsd.pbi_ppid),
                userID: bsd.pbi_uid,
                name: Self.processName(pid, fallback: bsd),
                executablePath: Self.executablePath(pid)
            )

            guard let usage = CapabilityProbe.probeRusage(pid) else {
                // Readable identity, unreadable counters: a real row with honest gaps
                // rather than a hidden process or a fabricated zero (Appendix F).
                inaccessible += 1
                snapshots.append(RawProcessSnapshot(
                    key: key,
                    capturedAt: capturedAt,
                    availability: .denied(.permissionDenied)
                ))
                continue
            }

            snapshots.append(RawProcessSnapshot(
                key: key,
                capturedAt: capturedAt,
                userTimeNS: usage.ri_user_time,
                systemTimeNS: usage.ri_system_time,
                // Section 5.4: physical footprint is the primary memory value; it
                // represents physical pressure better than virtual address size.
                physicalFootprintBytes: usage.ri_phys_footprint,
                residentBytes: usage.ri_resident_size,
                diskReadBytes: usage.ri_diskio_bytesread,
                diskWriteBytes: usage.ri_diskio_byteswritten,
                // Section 5.5: cumulative process-accounted energy.
                energyNJ: usage.ri_energy_nj,
                idleWakeups: usage.ri_pkg_idle_wkups,
                interruptWakeups: usage.ri_interrupt_wkups,
                availability: .ok
            ))
        }

        return Capture(
            snapshots: snapshots,
            rawIdentities: identities,
            inaccessibleCount: inaccessible,
            capturedAt: capturedAt
        )
    }

    // MARK: - libproc wrappers

    static func listPIDs() -> [pid_t] {
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { return [] }
        // Head-room for processes spawned between the sizing call and the read.
        var pids = [pid_t](repeating: 0, count: Int(probe) + 128)
        let written = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written))).filter { $0 > 0 }
    }

    /// The full bsdinfo rather than `proc_bsdshortinfo`: only this structure carries
    /// the process start time, and without that there is no `ProcessKey` (Section 6.1).
    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return result == size ? info : nil
    }

    /// Section 6.1: the identity half of a `ProcessKey`, in microseconds.
    static func startAbsoluteTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    static func processName(_ pid: pid_t, fallback: proc_bsdinfo) -> String {
        // pbi_name holds the registered name; pbi_comm is truncated to 16 characters,
        // so it is only the last resort.
        let registered = Self.string(from: fallback.pbi_name)
        if !registered.isEmpty { return registered }
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXPATHLEN))
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = Self.string(from: buffer)
            if !name.isEmpty { return name }
        }
        return Self.string(from: fallback.pbi_comm)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return Self.string(from: buffer)
    }

    /// Decodes a fixed-size C character buffer up to its null terminator.
    static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
