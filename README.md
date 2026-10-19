# ResourcesBar

A tiny macOS menu bar monitor for **CPU, Memory, Network and Disk**.

```
CPU 11%  MEM 15.7G  ↓ 31K ↑259K  DSK 77%
```

Menu bar labels (including network arrows and disk names) and click-open metric
labels share the appearance-aware system orange color. Values use the standard
appearance-aware text color for readability. Settings retain native menu styling.

Click the item for details: CPU user/system, memory and swap, network rates, space for **every mounted disk** (startup disk, external drives, mounted disk images), and total disk I/O. The menu also lets you choose which metrics appear in the menu bar, pick which disk the menu bar shows (**Menu Bar Disk**), change the update interval, and turn on launch at login.

Enable **Condensed Menu Bar** in the menu to save horizontal space with smaller,
9-point text arranged in two balanced rows. Network arrows stay together, and
only your selected metrics are shown. With just one metric selected, it is
centered on a single small-text row. The setting is saved across launches;
turn it off to restore the standard single-row layout. The detail menu stays
full size in either mode.

## Why it's light

- Single Swift file using AppKit; the build generates a colorful resource-meter
  app icon. Sparkle handles updates.
- Metrics are read directly from the kernel: `host_statistics` (CPU/memory), `sysctl NET_RT_IFLIST2` (network, 64-bit counters), IOKit `IOBlockStorageDriver` (disk I/O), and volume resource values (disk space, refreshed every 30s and immediately on mount/unmount).
- One timer (default 2s) with tolerance so macOS can coalesce wakeups. Polling pauses while the display sleeps, and the detail menu only updates while it's open.
- The sampler runs at ~0% CPU. Sparkle's framework and update helpers are bundled
  separately from the main executable.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.
The first build downloads Sparkle 2.10.0 from its official GitHub release,
verifies its pinned SHA-256 checksum, and caches it under `build/`.

```sh
./build.sh           # -> build/ResourcesBar.app (universal, ad-hoc signed; see build.sh for VERSION/SIGNING_IDENTITY)
./build.sh install   # also copies it to /Applications
open build/ResourcesBar.app
```

"Launch at Login" works best once the app is in `/Applications`.
Local builds without `SPARKLE_PUBLIC_ED_KEY` disable update controls and log why.
Set that environment variable to your public key to enable updates locally.

Run `sh test.sh` for menu bar layout and sampler regression tests and a live
sampling smoke test. The tests cover condensed layouts for every metric
selection, device addition/removal, counter resets, failed-read recovery,
and filtering remote or hidden mounts before querying capacity.
Run `swift Tests/UpdateReleaseTests.swift` to build an ad-hoc update with
ephemeral keys and verify its bundle configuration, appcast, and DMG signature.
This replaces the local `0.0.0` build artifacts; its keys are for testing only.

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
| `SPARKLE_PUBLIC_ED_KEY` | Public Ed25519 key printed by Sparkle's `generate_keys` |
| `SPARKLE_PRIVATE_ED_KEY` | Base64 private seed exported by Sparkle 2.10's `generate_keys -x` |

To upload them, copy `.env.example` to `.env` (gitignored), fill it in, then:

```sh
./Scripts/setup-release-secrets.sh --dry-run   # validate without uploading
./Scripts/setup-release-secrets.sh             # set them via gh secret set
```

### Automatic updates

Sparkle checks daily for updates from
`https://github.com/thorrsson/mac-resources-bar/releases/latest/download/appcast.xml`.
Users approve installation; silent installation is off by default. The menu
provides **Check for Updates…** and **Automatically Check for Updates** controls.
Scheduled updates also show **Update Available** in the menu bar and a
versioned menu action, so prompts cannot go unnoticed behind other apps.
Select that action to bring the pending update forward. The indicator clears
when the update receives attention or its session ends.
Keep the app in `/Applications`, not running from the disk image.

Before the first Sparkle-enabled release, generate a signing key once:

```sh
sh Scripts/fetch-sparkle.sh
build/Sparkle-2.10.0/bin/generate_keys
build/Sparkle-2.10.0/bin/generate_keys -x /secure/path/sparkle-private-key
```

The private key remains in your login Keychain. Back up the exported seed
securely; never commit it or rotate it casually. Put the printed public key and
the exported file's text into the two Sparkle entries in `.env`, then upload
the release secrets using the helper above. New 32-byte seed keys are required;
legacy Sparkle key exports are not accepted by the release script.

Release CI requires matching keys, embeds the public key in the app, signs the
final notarized DMG with Ed25519, and publishes `appcast.xml` with the DMG.
For a local signed feed, pass both keys as environment variables to
`Scripts/release.sh`. Without a private key, local/PR packaging skips the feed.
The appcast contains this release only and downloads from its versioned GitHub
release URL; publish stable versions in increasing order. `CFBundleVersion`
(the git commit count by default) must increase with every update; use
`BUILD_NUMBER` to override it if needed, including after rewriting history.

Existing installations without Sparkle need one manual upgrade to a
Sparkle-enabled release. The feed becomes available once that release is
published; building this branch alone does not enable production updates.

## Notes

- Memory "used" matches Activity Monitor: app memory + wired + compressed.
- Network counts physical interfaces only (`en*`, cellular). This avoids counting VPN traffic twice.
- Network and disk I/O deltas are tracked per device. Newly connected devices
  are primed without counting lifetime traffic; failed reads clear baselines
  so recovery does not inflate rates.
- Disks: all visible local volumes are listed, and network shares are skipped so an unresponsive server can't stall the app. Purgeable space counts as free, the same way Finder does. If the selected menu bar disk is ejected, the menu bar falls back to the startup disk.
- Mounts are filtered using cached kernel mount flags (`MNT_NOWAIT`) before
  reading volume names or capacity; remote volumes receive no resource queries.
