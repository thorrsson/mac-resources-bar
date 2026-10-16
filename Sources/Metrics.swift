import Foundation
import Darwin
import IOKit

struct VolumeUsage {
    let id: String
    let name: String
    let path: String
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
}

struct ResourceSnapshot {
    var cpu: Double?
    var memoryUsed: UInt64?
    var memoryTotal = ProcessInfo.processInfo.physicalMemory
    var networkIn: Double?
    var networkOut: Double?
    var diskRead: Double?
    var diskWrite: Double?
}

private struct Counters {
    let incoming: UInt64
    let outgoing: UInt64
}

final class ResourceSampler {
    private let host = mach_host_self()
    private var previousCPU: [UInt32]?
    private var previousNetwork: [String: Counters] = [:]
    private var previousDisks: [UInt64: Counters] = [:]
    private var previousTime: TimeInterval?

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func reset() {
        previousCPU = nil
        previousNetwork = [:]
        previousDisks = [:]
        previousTime = nil
    }

    func sample() -> ResourceSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        previousTime = now
        var result = ResourceSnapshot()
        result.cpu = cpuUsage()
        result.memoryUsed = memoryUsage()

        if let network = networkCounters() {
            let rates = rate(current: network, previous: previousNetwork, elapsed: elapsed)
            result.networkIn = rates?.0
            result.networkOut = rates?.1
            previousNetwork = network
        } else {
            previousNetwork = [:]
        }
        if let disks = diskCounters() {
            let rates = rate(current: disks, previous: previousDisks, elapsed: elapsed)
            result.diskRead = rates?.0
            result.diskWrite = rates?.1
            previousDisks = disks
        } else {
            previousDisks = [:]
        }
        return result
    }

    private func rate<Key: Hashable>(
        current: [Key: Counters], previous: [Key: Counters], elapsed: TimeInterval?
    ) -> (Double, Double)? {
        guard let elapsed, elapsed > 0, !current.isEmpty, !previous.isEmpty else { return nil }
        var incoming = 0.0
        var outgoing = 0.0
        for (key, value) in current {
            guard let old = previous[key] else { continue }
            // New devices and counter resets must not appear as throughput spikes.
            if value.incoming >= old.incoming {
                incoming += Double(value.incoming - old.incoming)
            }
            if value.outgoing >= old.outgoing {
                outgoing += Double(value.outgoing - old.outgoing)
            }
        }
        return (incoming / elapsed, outgoing / elapsed)
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            previousCPU = nil
            return nil
        }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousCPU = ticks }
        guard let previousCPU else { return nil }
        let delta = zip(ticks, previousCPU).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total)
    }

    private func memoryUsage() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let resident = UInt64(info.active_count) + UInt64(info.inactive_count)
            + UInt64(info.wire_count) + UInt64(info.speculative_count)
            + UInt64(info.compressor_page_count)
        let reclaimable = UInt64(info.purgeable_count) + UInt64(info.external_page_count)
        let pages = resident > reclaimable ? resident - reclaimable : 0
        return min(pages * UInt64(vm_kernel_page_size), ProcessInfo.processInfo.physicalMemory)
    }

    private func networkCounters() -> [String: Counters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var buffer = Data(count: size)
        let status = buffer.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= size - offset else { break }
                defer { offset += length }
                guard bytes[offset + 3] == UInt8(RTM_IFINFO2),
                      length >= MemoryLayout<if_msghdr2>.size else { continue }
                let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(cString: nameBuffer)
                // macOS names physical Ethernet, Wi-Fi and Thunderbolt interfaces en<N>.
                // Exclude utun, bridge, loopback and other logical interfaces.
                let suffix = name.dropFirst(2)
                guard name.hasPrefix("en"), !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
                      info.ifm_data.ifi_type == UInt8(IFT_ETHER) else { continue }
                result[name] = Counters(
                    incoming: info.ifm_data.ifi_ibytes, outgoing: info.ifm_data.ifi_obytes
                )
            }
        }
        return result
    }

    private func diskCounters() -> [UInt64: Counters]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: Counters] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let property = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue(),
                  let statistics = property as? [String: Any],
                  let read = statistics["Bytes (Read)"] as? NSNumber,
                  let written = statistics["Bytes (Write)"] as? NSNumber else { continue }
            result[id] = Counters(incoming: read.uint64Value, outgoing: written.uint64Value)
        }
        return result
    }
}

enum VolumeSampler {
    static func sample() -> [VolumeUsage] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        var seen: Set<String> = []
        return urls.compactMap { url -> VolumeUsage? in
            // Check locality before requesting capacity, so network servers are never queried.
            guard let location = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
                  location.volumeIsLocal == true,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false,
                  let capacity = values.volumeTotalCapacity, capacity > 0 else { return nil }
            let id = values.volumeUUIDString ?? url.path
            guard seen.insert(id).inserted else { return nil }
            let ordinary = Int64(values.volumeAvailableCapacity ?? 0)
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            // Some filesystems report zero for important-usage capacity even with free space.
            let available = min(Int64(capacity), max(ordinary, important))
            return VolumeUsage(
                id: id, name: values.volumeName ?? url.lastPathComponent,
                path: url.path, total: Int64(capacity), available: max(0, available)
            )
        }.sorted {
            if ($0.path == "/") != ($1.path == "/") { return $0.path == "/" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
