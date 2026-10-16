# ResourcesBar

A tiny macOS menu bar monitor for **CPU, Memory, Network and Disk**.

```
CPU 11%  MEM 15.7G  ↓ 31K ↑259K  DSK 77%
```

Menu bar labels (including network arrows and disk names) and click-open metric
labels share the appearance-aware system orange color. Values use the standard
appearance-aware text color for readability. Settings retain native menu styling.

Click the item for details: CPU user/system, memory and swap, network rates, space for **every mounted disk** (startup disk, external drives, mounted disk images), and total disk I/O. The menu also lets you choose which metrics appear in the menu bar, pick which disk the menu bar shows (**Menu Bar Disk**), change the update interval, and turn on launch at login.

## Why it's light

- Single Swift file using AppKit only: no SwiftUI, no dependencies, no assets.
- Metrics are read directly from the kernel: `host_statistics` (CPU/memory), `sysctl NET_RT_IFLIST2` (network, 64-bit counters), IOKit `IOBlockStorageDriver` (disk I/O), and volume resource values (disk space, refreshed every 30s and immediately on mount/unmount).
- One timer (default 2s) with tolerance so macOS can coalesce wakeups. Polling pauses while the display sleeps, and the detail menu only updates while it's open.
- Runs at about **11 MB** physical footprint and ~0% CPU. The binary is about 230 KB.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

```sh
./build.sh           # -> build/ResourcesBar.app (universal, ad-hoc signed; see build.sh for VERSION/SIGNING_IDENTITY)
./build.sh install   # also copies it to /Applications
open build/ResourcesBar.app
```

"Launch at Login" works best once the app is in `/Applications`.

Run `sh test.sh` for sampler regression tests and a live sampling smoke test.
The tests cover device addition/removal, counter resets, failed-read recovery,
and filtering remote or hidden mounts before querying capacity.

## Releases

`./Scripts/release.sh 1.2.3` builds `dist/ResourcesBar-1.2.3.dmg` plus a
`.sha256`. It signs with the first Developer ID Application identity in your
keychain (Hardened Runtime + secure timestamp), and notarizes and staples the
image when notary credentials are set (`NOTARY_PROFILE`, or
`NOTARY_API_KEY_ID` + `NOTARY_API_ISSUER_ID` + `NOTARY_API_KEY_P8`). Without an
identity or credentials it falls back to an unnotarized build.

CI (`.github/workflows/ci.yml`) runs the tests and builds an ad-hoc signed disk
image on every push and pull request. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which signs, notarizes, and publishes the disk
image to a GitHub release. It needs a `release` environment (give it a required
reviewer and limit it to `v*` tags) with these secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application cert + key, `base64 < cert.p12 \| tr -d '\n'` |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | App Store Connect issuer ID |
| `NOTARY_API_KEY_P8` | `AuthKey_<id>.p8`, as PEM or base64 |

## Notes

- Memory "used" matches Activity Monitor: app memory + wired + compressed.
- Network counts physical interfaces only (`en*`, cellular). This avoids counting VPN traffic twice.
- Network and disk I/O deltas are tracked per device. Newly connected devices
  are primed without counting lifetime traffic; failed reads clear baselines
  so recovery does not inflate rates.
- Disks: all visible local volumes are listed, and network shares are skipped so an unresponsive server can't stall the app. Purgeable space counts as free, the same way Finder does. If the selected menu bar disk is ejected, the menu bar falls back to the startup disk.
- Mounts are filtered using cached kernel mount flags (`MNT_NOWAIT`) before
  reading volume names or capacity; remote volumes receive no resource queries.
