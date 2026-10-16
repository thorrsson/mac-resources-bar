ResourcesBar
============

A small, native macOS 13+ menu bar resource monitor. No third-party dependencies,
background helper, network service, or administrator privileges are required.

Build and install
-----------------

On a Mac, install Apple's Xcode Command Line Tools (xcode-select --install), then:

    ./build.sh
    ditto build/ResourcesBar.app /Applications/ResourcesBar.app
    open /Applications/ResourcesBar.app

The script compiles optimized arm64 and x86_64 executables with the current macOS
SDK, combines them into a universal app, and ad-hoc signs the bundle. Build
products stay in build/. A Developer ID signature and notarization are needed
for normal distribution to other Macs; this script does not provide those.
Quit the running app before replacing it with a new build.

Usage
-----

Click the menu bar readings for details and settings. CPU, memory, network, and
the selected disk's available space are shown by default. Settings lets you
independently show or hide each reading, including aggregate disk I/O. Hiding
everything leaves a ResourcesBar menu button so settings remain accessible.

Memory is displayed as a size, not a percentage. Network arrows mean download
and upload per second. Disk I/O uses R (read) and W (write) per second. A dash
means a reading is not yet available; rate measurements need two samples.

In "Volumes / Menu bar disk", choose the local volume whose space should appear
in the menu bar. Each volume lists used, total, and available space. Visible
local volumes include external drives and mounted disk images. Hidden volumes
and network shares are excluded. Selection survives relaunches while the volume
is mounted. If the selection is ejected or absent on launch, the startup volume
is selected instead. Selecting a volume does not change disk I/O aggregation.

Settings persist in macOS user defaults:
  - Refresh interval: 1, 2 (default), 5, or 10 seconds.
  - Show in menu bar: CPU, memory, network, disk space, disk I/O.
  - Pause while display sleeps: on by default. Polling also pauses for system
    sleep. Waking starts fresh rate baselines rather than averaging across sleep.
  - Launch at login: uses macOS ServiceManagement. Keep the app in /Applications.
    If approval is required, System Settings opens to Login Items. Click the
    pending setting again to open that page. Once enabled, click to unregister.

Resource sampling happens on a serial utility queue, not the AppKit UI thread.
Volume capacities refresh every 30 seconds (at the next sample) and after
mount/unmount notifications; they are not queried every tick.

Metric definitions and limits
-----------------------------

CPU: system-wide busy percentage across all processors, from Mach CPU tick
deltas (user + system + nice). This is normalized to 0-100%, not 100% per core.

Memory: resident active, inactive, speculative, wired, and compressor pages,
minus purgeable and file-backed pages, capped at physical RAM. This estimates
app + wired + compressed usage, not memory pressure or the sum of process RSS.
Memory sizes use binary units; disk and transfer sizes use decimal units.

Network: 64-bit sysctl interface-byte counter deltas, summed across macOS physical
Ethernet/Wi-Fi/Thunderbolt en<N> interfaces. Loopback, bridge, VPN utun, and other
logical interfaces are excluded to avoid counting tunneled traffic twice.
This reports host interface traffic, not per-app usage or VPN payload bytes.

Disk I/O: IOKit IOBlockStorageDriver byte counter deltas, aggregated across
available storage drivers, independent of the disk-space picker. Filesystem
caches and storage-driver support can affect readings; this is not per-volume
or per-process I/O. Missing IOKit statistics are shown as unavailable.

Space: Foundation volume resource values. Available capacity includes purgeable
space when reported by the important-usage API. A zero or unsupported value from
that API falls back to ordinary available capacity. Shared APFS containers can
report shared free space; do not sum their capacities. Network volumes are
filtered for locality before requesting capacity, to avoid waiting on servers.

Counter resets, newly attached devices, and sleep/wake establish new baselines
instead of generating artificial traffic spikes. ResourcesBar does not log
samples, launch subprocesses, or perform network requests.

Validation
----------

There is no automated test suite. On macOS:

    ./build.sh
    lipo -archs build/ResourcesBar.app/Contents/MacOS/ResourcesBar
    codesign --verify --strict build/ResourcesBar.app
    open build/ResourcesBar.app

Confirm arm64 and x86_64 are listed, then manually check:
  - CPU responds to workload; RAM sizes and transfer rates look plausible beside
    Activity Monitor (definitions and refresh timing can differ).
  - Copy a large file and generate network traffic; rates return near zero when
    idle. Disk I/O stays aggregated when selecting a different space volume.
  - Mount an external volume and a disk image; both appear with plausible space.
    Select each, then eject it; the menu bar returns to startup-disk space.
  - Network shares do not appear. Check an APFS volume with purgeable space and
    a filesystem without important-usage capacity support if available.
  - Toggle every visibility option (including all off), change intervals, and
    relaunch to verify settings and mounted-volume selection persist.
  - Enable login launch, approve it if needed, and log out/in; then disable it.
  - Sleep/wake the display with pause enabled and disabled; verify polling
    resumes without stale rate spikes or duplicate timers.
  - Inspect ResourcesBar's idle CPU and memory in Activity Monitor. Footprint
    depends on hardware and OS; no fixed performance measurement is claimed.

The implementation was created on a Linux runner: Swift syntax and shell syntax
can be checked there, but AppKit/IOKit compilation, runtime sampler values,
signing, login behavior, and hot-plug UI behavior require macOS validation.
