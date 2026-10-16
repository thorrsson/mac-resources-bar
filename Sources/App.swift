import AppKit
import ServiceManagement

private enum Metric: String, CaseIterable {
    case cpu, memory, network, disk, diskIO

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk space"
        case .diskIO: return "Disk I/O"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let sampler = ResourceSampler()
    private let samplingQueue = DispatchQueue(label: "ResourcesBar.sampling", qos: .utility)
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let diskMenu = NSMenu()
    private var details: [Metric: NSMenuItem] = [:]
    private var visibilityItems: [Metric: NSMenuItem] = [:]
    private var intervalItems: [NSMenuItem] = []
    private var sleepItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var timer: Timer?
    private var snapshot = ResourceSnapshot()
    private var volumes: [VolumeUsage] = []
    private var lastVolumeRefresh: TimeInterval?
    private var volumeRefreshPending = true
    private var inFlight = false
    private var generation = 0
    private var displaySleeping = false
    private var systemSleeping = false

    private var visibleMetrics: Set<String> {
        Set(defaults.stringArray(forKey: "visibleMetrics") ?? [])
    }

    private var refreshInterval: TimeInterval {
        let value = defaults.double(forKey: "refreshInterval")
        return [1.0, 2.0, 5.0, 10.0].contains(value) ? value : 2
    }

    private var shouldPoll: Bool {
        !systemSleeping && !(displaySleeping && defaults.bool(forKey: "suspendOnDisplaySleep"))
    }

    private var selectedVolume: VolumeUsage? {
        let id = defaults.string(forKey: "selectedVolume")
        return volumes.first { $0.id == id } ?? volumes.first { $0.path == "/" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            "visibleMetrics": ["cpu", "memory", "network", "disk"],
            "refreshInterval": 2.0,
            "suspendOnDisplaySleep": true
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular
        )
        statusItem.menu = menu
        menu.delegate = self
        buildMenu()
        updateReadings()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didUnmountNotification, object: nil)
        center.addObserver(self, selector: #selector(sleepChanged(_:)),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sleepChanged(_:)),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sleepChanged(_:)),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sleepChanged(_:)),
                           name: NSWorkspace.didWakeNotification, object: nil)
        restartPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        let heading = item("ResourcesBar")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        for metric in Metric.allCases {
            let detail = item(metric.title)
            detail.isEnabled = false
            details[metric] = detail
            menu.addItem(detail)
        }
        let disks = item("Volumes / Menu bar disk")
        disks.submenu = diskMenu
        diskMenu.autoenablesItems = false
        menu.addItem(disks)
        menu.addItem(.separator())

        let preferences = NSMenu()
        preferences.autoenablesItems = false
        let visibility = NSMenu()
        visibility.autoenablesItems = false
        for metric in Metric.allCases {
            let toggle = item(metric.title, action: #selector(toggleMetric(_:)))
            toggle.representedObject = metric.rawValue
            visibilityItems[metric] = toggle
            visibility.addItem(toggle)
        }
        let shown = item("Show in menu bar")
        shown.submenu = visibility
        preferences.addItem(shown)

        let intervals = NSMenu()
        intervals.autoenablesItems = false
        for seconds in [1, 2, 5, 10] {
            let choice = item("\(seconds) second\(seconds == 1 ? "" : "s")",
                              action: #selector(changeInterval(_:)))
            choice.representedObject = NSNumber(value: seconds)
            intervalItems.append(choice)
            intervals.addItem(choice)
        }
        let refresh = item("Refresh interval")
        refresh.submenu = intervals
        preferences.addItem(refresh)
        sleepItem = item("Pause while display sleeps", action: #selector(toggleSleep))
        preferences.addItem(sleepItem)
        loginItem = item("Launch at login", action: #selector(toggleLogin))
        preferences.addItem(loginItem)
        let settings = item("Settings")
        settings.submenu = preferences
        menu.addItem(settings)
        let quit = item("Quit ResourcesBar", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        updatePreferences()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePreferences()
    }

    private func updatePreferences() {
        for (metric, item) in visibilityItems {
            item.state = visibleMetrics.contains(metric.rawValue) ? .on : .off
        }
        for item in intervalItems {
            item.state = (item.representedObject as? NSNumber)?.doubleValue == refreshInterval
                ? .on : .off
        }
        sleepItem.state = defaults.bool(forKey: "suspendOnDisplaySleep") ? .on : .off
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginItem.title = status == .requiresApproval
            ? "Launch at login (approval required…)" : "Launch at login"
    }

    private func restartPolling() {
        timer?.invalidate()
        timer = nil
        generation += 1
        inFlight = false
        samplingQueue.async { self.sampler.reset() }
        guard shouldPoll else { return }
        volumeRefreshPending = true
        poll()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = min(0.5, refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard shouldPoll, !inFlight else { return }
        inFlight = true
        let token = generation
        let refreshVolumes = volumeRefreshPending
            || (lastVolumeRefresh.map { ProcessInfo.processInfo.systemUptime - $0 >= 30 } ?? true)
        volumeRefreshPending = false
        samplingQueue.async {
            let snapshot = self.sampler.sample()
            let volumes = refreshVolumes ? VolumeSampler.sample() : nil
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.inFlight = false
                self.snapshot = snapshot
                if let volumes {
                    self.volumes = volumes
                    self.lastVolumeRefresh = ProcessInfo.processInfo.systemUptime
                    if let selected = self.defaults.string(forKey: "selectedVolume"),
                       !volumes.contains(where: { $0.id == selected }) {
                        self.defaults.removeObject(forKey: "selectedVolume")
                    }
                    self.updateDiskMenu()
                }
                self.updateReadings()
                if self.volumeRefreshPending { self.poll() }
            }
        }
    }

    @objc private func volumesChanged(_ notification: Notification) {
        volumeRefreshPending = true
        poll()
    }

    @objc private func sleepChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: displaySleeping = true
        case NSWorkspace.screensDidWakeNotification: displaySleeping = false
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        default: break
        }
        restartPolling()
    }

    private func updateDiskMenu() {
        diskMenu.removeAllItems()
        if volumes.isEmpty {
            let unavailable = item("No visible local volumes available")
            unavailable.isEnabled = false
            diskMenu.addItem(unavailable)
        }
        for volume in volumes {
            let choice = item(
                "\(volume.name): \(bytes(volume.used)) used / \(bytes(volume.total))"
                    + " · \(bytes(volume.available)) available",
                action: #selector(selectDisk(_:))
            )
            choice.representedObject = volume.id
            choice.toolTip = volume.path
            choice.state = volume.id == selectedVolume?.id ? .on : .off
            diskMenu.addItem(choice)
        }
    }

    private func updateReadings() {
        let cpu = snapshot.cpu.map { String(format: "%.0f%%", $0) } ?? "—"
        let memory = snapshot.memoryUsed.map { bytes(Int64($0), memory: true) } ?? "—"
        let network = "↓\(rate(snapshot.networkIn)) ↑\(rate(snapshot.networkOut))"
        let io = "R \(rate(snapshot.diskRead)) W \(rate(snapshot.diskWrite))"
        let disk = selectedVolume.map { "\(bytes($0.available)) free" } ?? "—"
        let compact: [Metric: String] = [
            .cpu: "CPU \(cpu)", .memory: "MEM \(memory)", .network: "NET \(network)",
            .disk: "DISK \(disk)", .diskIO: "I/O \(io)"
        ]
        let titles = Metric.allCases.filter { visibleMetrics.contains($0.rawValue) }
            .compactMap { compact[$0] }
        statusItem.button?.title = titles.isEmpty ? "ResourcesBar" : titles.joined(separator: "  ")
        statusItem.button?.toolTip = "ResourcesBar — CPU, memory, network and disk"
        details[.cpu]?.title = "CPU: \(cpu) used"
        details[.memory]?.title = "Memory: \(memory) used / "
            + bytes(Int64(snapshot.memoryTotal), memory: true)
        details[.network]?.title = "Network: \(network)"
        details[.diskIO]?.title = "Disk I/O (all disks): \(io)"
        details[.disk]?.title = selectedVolume.map {
            "\($0.name): \(bytes($0.used)) used / \(bytes($0.total)) · \(disk)"
        } ?? "Disk space: unavailable"
    }

    private func bytes(_ value: Int64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: memory ? .memory : .file)
    }

    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(Int64(min(value, Double(Int64.max / 2)))) + "/s"
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let metric = sender.representedObject as? String else { return }
        var visible = visibleMetrics
        if visible.contains(metric) { visible.remove(metric) } else { visible.insert(metric) }
        defaults.set(Array(visible), forKey: "visibleMetrics")
        updatePreferences()
        updateReadings()
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? NSNumber else { return }
        defaults.set(seconds.doubleValue, forKey: "refreshInterval")
        updatePreferences()
        restartPolling()
    }

    @objc private func toggleSleep() {
        defaults.set(!defaults.bool(forKey: "suspendOnDisplaySleep"),
                     forKey: "suspendOnDisplaySleep")
        updatePreferences()
        restartPolling()
    }

    @objc private func selectDisk(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        defaults.set(id, forKey: "selectedVolume")
        updateDiskMenu()
        updateReadings()
    }

    @objc private func toggleLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change launch at login"
            alert.informativeText = error.localizedDescription
                + "\nKeep ResourcesBar in /Applications and try again."
            alert.runModal()
        }
        updatePreferences()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
enum ResourcesBar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
