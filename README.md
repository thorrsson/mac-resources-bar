# ResourcesBar

A tiny macOS menu bar monitor for **CPU, Memory, Network and Disk**.

```
CPU 11%  MEM 15.7G  ↓ 31K ↑259K  DSK 77%
```

Click the item for details: CPU user/system, memory and swap, network rates, space for **every mounted disk** (startup disk, external drives, mounted disk images), and total disk I/O. The menu also lets you choose which metrics appear in the menu bar, pick which disk the menu bar shows (**Menu Bar Disk**), change the update interval, and turn on launch at login.

## Why it's light

- Single Swift file using AppKit only: no SwiftUI, no dependencies, no assets.
- Metrics are read directly from the kernel: `host_statistics` (CPU/memory), `sysctl NET_RT_IFLIST2` (network, 64-bit counters), IOKit `IOBlockStorageDriver` (disk I/O), and volume resource values (disk space, refreshed every 30s and immediately on mount/unmount).
- One timer (default 2s) with tolerance so macOS can coalesce wakeups. Polling pauses while the display sleeps, and the detail menu only updates while it's open.
- Runs at about **11 MB** physical footprint and ~0% CPU. The binary is about 230 KB.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

```sh
./build.sh           # -> build/ResourcesBar.app (universal, ad-hoc signed)
./build.sh install   # also copies it to /Applications
open build/ResourcesBar.app
```

"Launch at Login" works best once the app is in `/Applications`.

## Notes

- Memory "used" matches Activity Monitor: app memory + wired + compressed.
- Network counts physical interfaces only (`en*`, cellular). This avoids counting VPN traffic twice.
- Disks: all visible local volumes are listed, and network shares are skipped so an unresponsive server can't stall the app. Purgeable space counts as free, the same way Finder does. If the selected menu bar disk is ejected, the menu bar falls back to the startup disk.
