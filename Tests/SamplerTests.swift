import AppKit

struct SamplerTests {
    static func counters(_ input: UInt64, _ output: UInt64) -> ByteCounters {
        ByteCounters(input: input, output: output)
    }

    static func expect(_ value: ByteCounters?, _ input: UInt64, _ output: UInt64) {
        precondition(value?.input == input && value?.output == output)
    }

    static func testBaselines<Key: Hashable>(_ first: Key, _ second: Key) {
        var tracker = CounterBaselines<Key>()
        precondition(tracker.sample([first: counters(100, 200)]) == nil)
        expect(tracker.sample([first: counters(110, 220)]), 10, 20)
        // A newly connected device's lifetime counters are not interval traffic.
        expect(tracker.sample([first: counters(120, 240), second: counters(10_000, 20_000)]), 10, 20)
        expect(tracker.sample([first: counters(130, 260), second: counters(10_005, 20_007)]), 15, 27)
        // Removing a busy device must not erase another device's traffic.
        expect(tracker.sample([first: counters(140, 280)]), 10, 20)
        expect(tracker.sample([first: counters(150, 300), second: counters(30_000, 40_000)]), 10, 20)
        // Counter resets do not underflow.
        expect(tracker.sample([first: counters(1, 2), second: counters(30_001, 40_002)]), 1, 2)
        // A failed read discards all baselines; recovery primes rather than inflating rates.
        precondition(tracker.sample(nil) == nil)
        precondition(tracker.sample([first: counters(50_000, 60_000)]) == nil)
        expect(tracker.sample([first: counters(50_010, 60_020)]), 10, 20)
        expect(tracker.sample([:]), 0, 0)
        expect(tracker.sample([first: counters(70_000, 80_000)]), 0, 0)
    }

    static func mount(_ path: String, _ flags: Int32) -> statfs {
        var value = statfs()
        value.f_flags = UInt32(flags)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &value.f_mntonname) { destination in
            destination.copyBytes(from: bytes)
        }
        return value
    }

    static func testMenuBarPresentation() {
        let metrics = ["CPU100%", "MEM  99.9G", "↓999M ↑999M", "External 100%"]
        func readings(_ texts: [String], size: CGFloat) -> [NSAttributedString] {
            texts.map {
                NSAttributedString(string: $0, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            }
        }
        for selection in 0..<16 {
            let selected = metrics.enumerated().compactMap { selection & (1 << $0.offset) != 0 ? $0.element : nil }
            let texts = selected.isEmpty ? ["RB"] : selected
            let standard = MenuBarPresentation(readings: readings(texts, size: 11), condensed: false)
            let condensed = MenuBarPresentation(readings: readings(texts, size: 9), condensed: true)
            precondition(standard.rows.count == 1)
            precondition(standard.rows[0].string == texts.joined(separator: "  "))
            precondition(condensed.rows.count == (texts.count > 1 ? 2 : 1))
            precondition(condensed.accessibilityLabel == standard.accessibilityLabel)
            precondition(condensed.image.size.height <= 22)
            precondition(condensed.rows.allSatisfy {
                $0.size().height <= condensed.image.size.height / CGFloat(condensed.rows.count)
            })
            precondition(condensed.image.size.width < standard.rows[0].size().width)
            precondition(condensed.image.tiffRepresentation != nil)
            if selection == 15 {
                precondition(condensed.image.size.width < standard.rows[0].size().width * 0.6)
            }
        }
        let update = MenuBarPresentation(readings: readings(metrics + ["Update Available"], size: 9), condensed: true)
        precondition(update.rows.count == 2)
        precondition(update.accessibilityLabel.contains("Update Available"))
        precondition(update.accessibilityLabel.contains("↓999M ↑999M"))
        let label = NSAttributedString(string: "CPU", attributes: [.foregroundColor: NSColor.systemOrange])
        let colored = MenuBarPresentation(readings: [label, label], condensed: true)
        precondition(colored.rows.allSatisfy {
            $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange
        })
    }

    static func main() {
        testMenuBarPresentation()
        testBaselines("1:en0", "2:en1")
        testBaselines(UInt64(100), UInt64(200))

        let mounts = [
            mount("/", MNT_LOCAL),
            mount("/Volumes/External", MNT_LOCAL),
            mount("/Volumes/Installer", MNT_LOCAL | MNT_RDONLY),
            mount("/Volumes/Writable Image", MNT_LOCAL),
            mount("/Volumes/Read-only Drive", MNT_LOCAL | MNT_RDONLY),
            mount("/Volumes/Unknown", MNT_LOCAL),
            mount("/Volumes/SMB", 0),
            mount("/Volumes/NFS", 0),
            mount("/System/Volumes/Data", MNT_LOCAL | MNT_DONTBROWSE),
        ]
        var queriedPaths: [String] = []
        mounts.withUnsafeBufferPointer {
            let paths = DiskSpaceSampler.localVolumePaths($0) { path in
                queriedPaths.append(path)
                switch path {
                case "/Volumes/Installer", "/Volumes/Writable Image": return "Disk Image"
                case "/": return "APPLE SSD"
                case "/Volumes/Unknown": return nil
                default: return "External SSD"
                }
            }
            precondition(paths == ["/", "/Volumes/External", "/Volumes/Read-only Drive", "/Volumes/Unknown"])
        }
        precondition(queriedPaths == [
            "/", "/Volumes/External", "/Volumes/Installer", "/Volumes/Writable Image",
            "/Volumes/Read-only Drive", "/Volumes/Unknown",
        ])
        // Exercise the real Mach/sysctl/IOKit paths as well as deterministic regressions.
        let cpu = CPUSampler(), network = NetworkSampler(), disks = DiskIOSampler()
        _ = cpu.sample()
        _ = network.sample()
        _ = disks.sample()
        Thread.sleep(forTimeInterval: 0.1)
        precondition(cpu.sample() != nil)
        precondition(network.sample() != nil)
        precondition(disks.sample() != nil)
        let volumes = DiskSpaceSampler.sample()
        precondition(volumes.contains { $0.path == "/" })
        precondition(volumes.allSatisfy { $0.total > 0 && $0.used <= $0.total })
        for excludedPath in CommandLine.arguments.dropFirst() {
            precondition(FileManager.default.fileExists(atPath: excludedPath))
            precondition(!volumes.contains { $0.path == excludedPath })
        }
        print("Menu bar layout, sampler regressions and live sampling passed.")
    }
}
