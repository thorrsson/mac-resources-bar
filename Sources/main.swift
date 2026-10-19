import AppKit
import IOKit
import ServiceManagement
#if !TESTING
import Sparkle
#endif

private let hostPort = mach_host_self()

// MARK: - Formatting

private let figureSpace = "\u{2007}"  // same width as a digit in monospaced-digit fonts

private func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: figureSpace, count: width - s.count) + s
}

private func percent(_ v: Double) -> String {
    padLeft("\(Int((v * 100).rounded()))%", 4)
}

private func coloredReading(
    _ label: String, _ value: String,
    font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
) -> NSAttributedString {
    let text = NSMutableAttributedString(string: label, attributes: [
        .font: font, .foregroundColor: NSColor.systemOrange,
    ])
    text.append(NSAttributedString(string: value, attributes: [
        .font: font, .foregroundColor: NSColor.labelColor,
    ]))
    return text
}

private func setMenuReading(_ item: NSMenuItem, _ label: String, _ value: String) {
    let text = coloredReading(label, value, font: .menuFont(ofSize: 0))
    item.title = text.string
    item.attributedTitle = text
}

struct MenuBarPresentation {
    let rows: [NSAttributedString]

    init(readings: [NSAttributedString], condensed: Bool) {
        func joined(_ readings: ArraySlice<NSAttributedString>) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for reading in readings {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "  ", attributes: reading.attributes(at: 0, effectiveRange: nil)))
                }
                result.append(reading)
            }
            return result
        }

        guard condensed, readings.count > 1 else {
            rows = [joined(readings[...])]
            return
        }
        let split = (1..<readings.count).min {
            max(joined(readings[..<$0]).size().width, joined(readings[$0...]).size().width)
                < max(joined(readings[..<$1]).size().width, joined(readings[$1...]).size().width)
        }!
        rows = [joined(readings[..<split]), joined(readings[split...])]
    }

    var accessibilityLabel: String { rows.map(\.string).joined(separator: "  ") }

    var image: NSImage {
        let size = NSSize(width: ceil(rows.map { $0.size().width }.max() ?? 0), height: 22)
        // Draw within the status button rather than relying on its single-line title cell.
        return NSImage(size: size, flipped: false) { rect in
            let rowHeight = rect.height / CGFloat(rows.count)
            for (index, row) in rows.enumerated() {
                let bounds = row.size()
                row.draw(at: NSPoint(
                    x: floor((rect.width - bounds.width) / 2),
                    y: rect.height - rowHeight * CGFloat(index + 1) + (rowHeight - bounds.height) / 2
                ))
            }
            return true
        }
    }
}

private func compactRate(_ bytesPerSec: Double) -> String {
    let k = bytesPerSec / 1024
    if k < 999.5 { return padLeft(String(format: "%.0fK", k), 4) }
    let m = k / 1024
    if m < 9.95 { return String(format: "%.1fM", m) }
    if m < 999.5 { return padLeft(String(format: "%.0fM", m), 4) }
    return String(format: "%.1fG", m / 1024)
}

private func compactBytes(_ bytes: UInt64) -> String {
    let m = Double(bytes) / 1_048_576
    if m < 999.5 { return padLeft(String(format: "%.0fM", m), 5) }
    let g = m / 1024
    if g < 99.95 { return padLeft(String(format: "%.1fG", g), 5) }
    return padLeft(String(format: "%.0fG", g), 5)
}

private let memFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    return f
}()

private let fileFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

private func mem(_ v: UInt64) -> String { memFormatter.string(fromByteCount: Int64(clamping: v)) }
private func file(_ v: UInt64) -> String { fileFormatter.string(fromByteCount: Int64(clamping: v)) }
private func rate(_ v: Double) -> String { fileFormatter.string(fromByteCount: Int64(v)) + "/s" }

private func delta(_ cur: UInt64, _ prev: UInt64) -> UInt64 { cur >= prev ? cur - prev : 0 }

struct ByteCounters {
    let input: UInt64
    let output: UInt64
}

struct CounterBaselines<Key: Hashable> {
    private var previous: [Key: ByteCounters]?

    mutating func sample(_ current: [Key: ByteCounters]?) -> ByteCounters? {
        defer { previous = current }
        guard let current = current, let previous = previous else { return nil }
        var input: UInt64 = 0, output: UInt64 = 0
        for (key, counters) in current {
            guard let old = previous[key] else { continue }
            input &+= delta(counters.input, old.input)
            output &+= delta(counters.output, old.output)
        }
        return ByteCounters(input: input, output: output)
    }
}

// MARK: - Samplers

final class CPUSampler {
    private var prev: host_cpu_load_info?

    /// Returns (user, system) fractions of total CPU time since the previous call.
    func sample() -> (user: Double, system: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            prev = nil
            NSLog("ResourcesBar: CPU sample failed: \(kr)")
            return nil
        }
        defer { prev = info }
        guard let p = prev else { return nil }
        let c = info.cpu_ticks, q = p.cpu_ticks
        let user = Double(c.0 &- q.0) + Double(c.3 &- q.3)  // USER + NICE
        let system = Double(c.1 &- q.1)
        let idle = Double(c.2 &- q.2)
        let total = user + system + idle
        guard total > 0 else { return (0, 0) }
        return (user / total, system / total)
    }
}

enum MemorySampler {
    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(hostPort, &size)
        return UInt64(size)
    }()
    static let total = ProcessInfo.processInfo.physicalMemory

    /// "Used" as Activity Monitor reports it: app memory + wired + compressed.
    static func sample() -> (used: UInt64, swap: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return (min(used, total), swapUsed)
    }
}

/// Total bytes in/out across physical interfaces (en*, cellular), using 64-bit counters.
final class NetworkSampler {
    private var buffer = [UInt8]()
    private var baselines = CounterBaselines<String>()

    func sample() -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return failedSample() }
        if buffer.count < len { buffer = [UInt8](repeating: 0, count: len + 1024) }
        guard sysctl(&mib, 6, &buffer, &len, nil, 0) == 0 else { return failedSample() }

        var counters: [String: ByteCounters] = [:]
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if m.ifm_flags & IFF_UP != 0, m.ifm_flags & IFF_LOOPBACK == 0,
                       if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        if n.hasPrefix("en") || n.hasPrefix("pdp_ip") {
                            counters["\(m.ifm_index):\(n)"] = ByteCounters(
                                input: m.ifm_data.ifi_ibytes, output: m.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        guard let change = baselines.sample(counters) else { return nil }
        return (change.input, change.output)
    }

    private func failedSample() -> (inBytes: UInt64, outBytes: UInt64)? {
        NSLog("ResourcesBar: network sample failed: \(errno)")
        _ = baselines.sample(nil)
        return nil
    }
}

/// Total bytes read/written across block storage drivers.
final class DiskIOSampler {
    private var baselines = CounterBaselines<UInt64>()

    func sample() -> (read: UInt64, write: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else {
            return failedSample()
        }
        defer { IOObjectRelease(iter) }
        var counters: [UInt64: ByteCounters] = [:]
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary,
                  let read = stats["Bytes (Read)"] as? NSNumber,
                  let write = stats["Bytes (Write)"] as? NSNumber else { return failedSample() }
            counters[id] = ByteCounters(input: read.uint64Value, output: write.uint64Value)
        }
        guard IOIteratorIsValid(iter) != 0 else { return failedSample() }
        guard let change = baselines.sample(counters) else { return nil }
        return (change.input, change.output)
    }

    private func failedSample() -> (read: UInt64, write: UInt64)? {
        NSLog("ResourcesBar: disk I/O sample failed; resetting baselines")
        _ = baselines.sample(nil)
        return nil
    }
}

struct Volume {
    let path: String
    let name: String
    let used: UInt64
    let total: UInt64
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Space usage for every visible local volume (startup disk, external drives, mounted images).
/// Network shares are skipped so a stale server can never stall the UI.
enum DiskSpaceSampler {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]

    static func localVolumePaths(_ mounts: UnsafeBufferPointer<statfs>) -> [String] {
        mounts.compactMap { mount in
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0,
                  mount.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            var path = mount.f_mntonname
            return withUnsafeBytes(of: &path) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
    }

    static func sample() -> [Volume] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts = mounts else {
            NSLog("ResourcesBar: mount enumeration failed: \(errno)")
            return []
        }
        // MNT_NOWAIT reads cached kernel metadata without contacting any filesystem.
        let paths = localVolumePaths(UnsafeBufferPointer(start: mounts, count: Int(count)))
        var volumes: [Volume] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            // "Important usage" counts purgeable space as free (like Finder) but reports 0 on some
            // filesystems (e.g. read-only images), so take whichever is larger.
            let avail = max(Int(v.volumeAvailableCapacityForImportantUsage ?? 0), v.volumeAvailableCapacity ?? 0)
            let t = UInt64(total), a = UInt64(max(0, avail))
            volumes.append(Volume(path: url.path, name: v.volumeName ?? url.lastPathComponent,
                                  used: t - min(a, t), total: t))
        }
        // Startup disk first, then alphabetical.
        return volumes.sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}

// MARK: - App

private enum Metric: Int, CaseIterable {
    case cpu, memory, network, disk
    var label: String { ["CPU", "Memory", "Network", "Disk"][rawValue] }
    var defaultsKey: String { "show.\(rawValue)" }
}

private struct Snapshot {
    var cpuUser = 0.0, cpuSystem = 0.0
    var memUsed: UInt64 = 0, swapUsed: UInt64 = 0
    var netIn = 0.0, netOut = 0.0
    var volumes: [Volume] = []
    var diskRead = 0.0, diskWrite = 0.0
    var ready = false
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let cpuItem = NSMenuItem(), memItem = NSMenuItem(), swapItem = NSMenuItem()
    private let netItem = NSMenuItem(), diskIOItem = NSMenuItem()
    private var volumeItems: [NSMenuItem] = []
    private let barDiskMenu = NSMenu()
    private var metricItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private let condensedItem = NSMenuItem(title: "Condensed Menu Bar", action: #selector(toggleCondensed(_:)), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
#if !TESTING
    private var updaterController: SPUStandardUpdaterController?
    private var pendingUpdateVersion: String?
    private let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
    private let automaticUpdatesItem = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: "")
#endif

    private let cpu = CPUSampler(), net = NetworkSampler(), diskIO = DiskIOSampler()
    private var snap = Snapshot()
    private var timer: Timer?
    private var lastTick = 0.0, lastDiskSpace = -Double.infinity
    private var menuOpen = false
    private let defaults = UserDefaults.standard

    private var interval: TimeInterval {
        let v = defaults.double(forKey: "interval")
        return v > 0 ? v : 2
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0.defaultsKey, true) }))
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem.button?.title = "…"
#if !TESTING
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           Data(base64Encoded: key)?.count == 32 {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
            )
        } else {
            NSLog("ResourcesBar: updates disabled because SUPublicEDKey is missing or invalid.")
        }
#endif
        buildMenu()
        statusItem.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(stopTimer), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(startTimer), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)

        tick()  // prime delta-based samplers
        startTimer()
    }

    // MARK: Timer

    @objc private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.25  // let the OS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)  // keep updating while the menu is open
        timer = t
    }

    @objc private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - lastTick, 0.001)
        lastTick = now

        if let c = cpu.sample() { snap.cpuUser = c.user; snap.cpuSystem = c.system; snap.ready = true }
        if let m = MemorySampler.sample() { snap.memUsed = m.used; snap.swapUsed = m.swap }
        if let n = net.sample() { snap.netIn = Double(n.inBytes) / elapsed; snap.netOut = Double(n.outBytes) / elapsed }
        if let d = diskIO.sample() { snap.diskRead = Double(d.read) / elapsed; snap.diskWrite = Double(d.write) / elapsed }
        if now - lastDiskSpace >= 30 { refreshVolumes(now) }

        guard snap.ready else { return }
        updateTitle()
        if menuOpen { updateMenu() }
    }

    private func refreshVolumes(_ now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let old = snap.volumes.map { "\($0.path)|\($0.name)" }
        snap.volumes = DiskSpaceSampler.sample()
        lastDiskSpace = now
        if snap.volumes.map({ "\($0.path)|\($0.name)" }) != old || volumeItems.isEmpty { rebuildVolumeItems() }
    }

    @objc private func volumesChanged() {
        refreshVolumes()
        guard snap.ready else { return }
        updateTitle()
        if menuOpen { updateMenu() }
    }

    private var barDiskPath: String { defaults.string(forKey: "barDisk") ?? "/" }

    /// The volume shown in the menu bar; falls back to the startup disk if the chosen one is unmounted.
    private var barVolume: Volume? {
        snap.volumes.first { $0.path == barDiskPath } ?? snap.volumes.first { $0.path == "/" }
    }

    private func isShown(_ m: Metric) -> Bool { defaults.bool(forKey: m.defaultsKey) }

    private func updateTitle() {
        let condensed = defaults.bool(forKey: "condensedMenuBar")
        let font = NSFont.monospacedDigitSystemFont(ofSize: condensed ? 9 : 11, weight: .regular)
        var readings: [NSAttributedString] = []
        func append(_ label: String, _ value: String) {
            readings.append(coloredReading(label, value, font: font))
        }
        if isShown(.cpu) { append("CPU", percent(snap.cpuUser + snap.cpuSystem)) }
        if isShown(.memory) { append("MEM ", compactBytes(snap.memUsed)) }
        if isShown(.network) {
            let network = NSMutableAttributedString(attributedString: coloredReading("↓", compactRate(snap.netIn), font: font))
            network.append(coloredReading(" ↑", compactRate(snap.netOut), font: font))
            readings.append(network)
        }
        if isShown(.disk), let v = barVolume {
            let label = v.path == "/" ? "DSK" : String(v.name.prefix(8)) + " "
            append(label, percent(v.fraction))
        }
        if readings.isEmpty { append("RB", "") }
#if !TESTING
        if pendingUpdateVersion != nil {
            append("Update Available", "")
        }
#endif
        let presentation = MenuBarPresentation(readings: readings, condensed: condensed)
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        if condensed {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = presentation.image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        } else {
            button.image = nil
            button.imagePosition = .noImage
            let title = presentation.rows[0]
            if !button.attributedTitle.isEqual(to: title) {
                button.attributedTitle = title
            }
        }
    }

    private func updateMenu() {
        let total = MemorySampler.total
        setMenuReading(cpuItem, "CPU: ", String(format: "%.0f%%  (user %.0f%%, system %.0f%%)",
                       (snap.cpuUser + snap.cpuSystem) * 100, snap.cpuUser * 100, snap.cpuSystem * 100))
        setMenuReading(memItem, "Memory: ", String(format: "%@ of %@  (%.0f%%)",
                       mem(snap.memUsed), mem(total), Double(snap.memUsed) / Double(total) * 100))
        setMenuReading(swapItem, "Swap used: ", mem(snap.swapUsed))
        setMenuReading(netItem, "Network: ", "↓ \(rate(snap.netIn))   ↑ \(rate(snap.netOut))")
        for (item, v) in zip(volumeItems, snap.volumes) {
            setMenuReading(item, v.name + ": ", String(format: "%@ of %@ used  (%@ free, %.0f%%)",
                           file(v.used), file(v.total), file(v.total - v.used), v.fraction * 100))
        }
        if snap.volumes.isEmpty, let item = volumeItems.first {
            setMenuReading(item, "Disks: ", "none")
        }
        setMenuReading(diskIOItem, "Disk I/O (all disks): ",
                       "read \(rate(snap.diskRead))   write \(rate(snap.diskWrite))")
    }

    /// Recreates the per-volume rows and the "Menu Bar Disk" picker after mounts/unmounts.
    private func rebuildVolumeItems() {
        volumeItems.forEach { menu.removeItem($0) }
        volumeItems = snap.volumes.map { _ in NSMenuItem(title: "…", action: nil, keyEquivalent: "") }
        if volumeItems.isEmpty { volumeItems = [NSMenuItem(title: "Disks: none", action: nil, keyEquivalent: "")] }
        var index = menu.index(of: diskIOItem)
        for item in volumeItems {
            menu.insertItem(item, at: index)
            index += 1
        }

        barDiskMenu.removeAllItems()
        let selected = barVolume?.path
        for v in snap.volumes {
            let item = NSMenuItem(title: v.name, action: #selector(selectBarDisk(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.path
            item.state = v.path == selected ? .on : .off
            barDiskMenu.addItem(item)
        }
    }

    @objc private func selectBarDisk(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        defaults.set(path, forKey: "barDisk")
        barDiskMenu.items.forEach { $0.state = $0 === sender ? .on : .off }
        updateTitle()
    }

    // MARK: Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [cpuItem, memItem, swapItem, netItem, diskIOItem] {
            item.title = "…"
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let showMenu = NSMenu()
        for m in Metric.allCases {
            let item = NSMenuItem(title: m.label, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m.rawValue
            item.state = isShown(m) ? .on : .off
            showMenu.addItem(item)
            metricItems.append(item)
        }
        let showItem = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        showItem.submenu = showMenu
        menu.addItem(showItem)

        condensedItem.target = self
        condensedItem.state = defaults.bool(forKey: "condensedMenuBar") ? .on : .off
        menu.addItem(condensedItem)

        let barDiskItem = NSMenuItem(title: "Menu Bar Disk", action: nil, keyEquivalent: "")
        barDiskItem.submenu = barDiskMenu
        menu.addItem(barDiskItem)

        let intervalMenu = NSMenu()
        for secs in [1, 2, 5, 10] {
            let item = NSMenuItem(title: "\(secs)s", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = secs
            item.state = Int(interval) == secs ? .on : .off
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        let intervalItem = NSMenuItem(title: "Update Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
#if !TESTING
        checkForUpdatesItem.target = self
        automaticUpdatesItem.target = self
        checkForUpdatesItem.isEnabled = false
        automaticUpdatesItem.isEnabled = updaterController != nil
        menu.addItem(checkForUpdatesItem)
        menu.addItem(automaticUpdatesItem)
        menu.addItem(.separator())
#endif
        menu.addItem(NSMenuItem(title: "Quit ResourcesBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
#if !TESTING
        checkForUpdatesItem.isEnabled = pendingUpdateVersion != nil || (updaterController?.updater.canCheckForUpdates ?? false)
        automaticUpdatesItem.state = updaterController?.updater.automaticallyChecksForUpdates == true ? .on : .off
#endif
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

#if !TESTING
    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updaterController?.checkForUpdates(sender)
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
        sender.state = updater.automaticallyChecksForUpdates ? .on : .off
    }
#endif

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let m = Metric(rawValue: sender.tag) else { return }
        let show = !isShown(m)
        defaults.set(show, forKey: m.defaultsKey)
        sender.state = show ? .on : .off
        updateTitle()
    }

    @objc private func toggleCondensed(_ sender: NSMenuItem) {
        let condensed = !defaults.bool(forKey: "condensedMenuBar")
        defaults.set(condensed, forKey: "condensedMenuBar")
        sender.state = condensed ? .on : .off
        updateTitle()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        defaults.set(Double(sender.tag), forKey: "interval")
        intervalItems.forEach { $0.state = $0 === sender ? .on : .off }
        startTimer()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("ResourcesBar: launch-at-login change failed: \(error)")
        }
        sender.state = svc.status == .enabled ? .on : .off
    }
}

#if !TESTING
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !state.userInitiated {
            setPendingUpdateVersion(update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setPendingUpdateVersion(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        setPendingUpdateVersion(nil)
    }

    private func setPendingUpdateVersion(_ version: String?) {
        pendingUpdateVersion = version
        checkForUpdatesItem.title = version.map { "Update Available (v\($0))…" } ?? "Check for Updates…"
        checkForUpdatesItem.isEnabled = version != nil || (updaterController?.updater.canCheckForUpdates ?? false)
        updateTitle()
    }
}
#endif

#if TESTING
SamplerTests.main()
#else
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
