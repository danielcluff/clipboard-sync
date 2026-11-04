# Clipboard Sync

Clipboard Sync **0.2.1** is a small LAN clipboard-sync tray application with a **Zig 0.17** engine and native
clipboard/menu adapters for macOS, Windows, and Linux X11. Copy on one paired
computer; the app automatically updates the clipboard on the others. No extra
“send” action, server, account, or cloud service.

This is an initial implementation. macOS and Windows builds have been verified
on the development Mac; Windows/Linux desktop behavior still needs the manual
checks below. Native Wayland support is not implemented.

## Features

- Automatic UTF-8 plain-text sync, checking for clipboard changes every 200 ms.
- One copied file at a time, up to **5 MiB (5,242,880 bytes)**, including ZIPs.
  Copy in Finder, Explorer, or a supported Linux file manager; paste into a file
  manager on another computer. File contents transfer, rather than source paths.
- Tray/menu-bar history of the ten most recent distinct items. Clicking an item
  restores it locally and shares it with paired devices. History lives in memory.
- Nearby discovery using IPv4 UDP broadcasts, with manual IPv4 entry as a fallback.
- Exact app-version checks: incompatible and unversioned devices stay hidden and cannot pair or sync.
- Explicit pairing, persistent trusted devices, forgetting devices, and pause/resume.
- ChaCha20-Poly1305 authenticated encryption with a separate derived secret per pair.
- Six-digit, single-use pairing codes with a two-minute expiry and a five-attempt limit.
- Event IDs stop relayed copies circulating around groups of paired devices.
- Authenticated address recovery when a paired device announces a new DHCP address.

## Build and run

Install **Zig 0.17.0**. There are no downloaded Zig package dependencies.

```sh
zig build test --summary all
zig build -Doptimize=ReleaseSafe
zig build run
```

On macOS, launch `zig-out/Clipboard Sync.app`. On Windows, launch
`zig-out/bin/clipboard-sync.exe`; Linux uses `zig-out/bin/clipboard-sync`.
Run it on each computer. macOS shows **⇄** in the menu bar; Windows shows a system
tray icon. Open the top **Sync active / paired count** submenu to see paired devices
and forget a device. **Connect** contains nearby discovery and pairing actions only.
Quit and pause/resume are available in the main menu.

### macOS

Install Apple's Command Line Tools (`xcode-select --install`). If Zig cannot find
AppKit/Foundation, supply the SDK explicitly:

```sh
zig build -Doptimize=ReleaseSafe -Dmacos-sdk="$(xcrun --show-sdk-path)"
open "zig-out/Clipboard Sync.app"
```

You can also double-click **Clipboard Sync.app** in Finder or copy it into
Applications. It launches directly into the menu bar without a Terminal window or
Dock icon, and keeps running independently of the launching terminal. `zig build run`
also launches this bundle through macOS LaunchServices. Use the menu's **Quit
Clipboard Sync** command to exit. Quit any older terminal-launched instance first.

### Windows

Build natively with Zig, or cross-compile from macOS/Linux:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows
```

Run the resulting EXE; allow **private-network** firewall access if prompted.
The app uses Unicode clipboard text and Explorer's `CF_HDROP` file format.

### Linux

Install GTK 3 development headers and pkg-config, then build natively:

```sh
# Debian / Ubuntu
sudo apt-get install libgtk-3-dev pkg-config
zig build -Doptimize=ReleaseSafe
./zig-out/bin/clipboard-sync
```

This backend explicitly uses **X11** (or XWayland for X11 applications). It uses
GTK's legacy status icon and `text/uri-list` / GNOME copied-file formats. The desktop
must support legacy tray icons; some desktops require a tray extension. Native
Wayland applications are not guaranteed to share this clipboard. A dedicated
Wayland data-control/portal backend and modern StatusNotifier tray are future work.
Cross-compiling Linux also requires target GTK libraries and a matching sysroot;
Zig cannot supply third-party desktop libraries automatically.

## Pair two computers

1. On computer B, open **Connect → Allow a new device…**. A six-digit
   code appears in a live window. Leave it open while you pair; the app keeps
   processing connections. The code expires two minutes after it is generated.
2. On computer A, open **Connect** and select B from nearby devices. Enter B's code, including any leading zeros.
   If discovery is blocked, choose **Connect by IP address…** instead.
3. Both menus show the paired device after the authenticated reply arrives.
4. Copy normally on either computer, then paste on the other.

Pairing codes authorize a fresh SPAKE2-P256 exchange with mutual key confirmation,
based on [RFC 9382](https://www.rfc-editor.org/rfc/rfc9382.html). The PIN is never
sent over the network or used directly as the clipboard encryption key. Codes expire
after two minutes, accept at most five exchange attempts, and close after one
successful pairing. Abandoned exchanges count toward the attempt limit. Choose
**Allow a new device…** again to generate a fresh code if it expires or locks out.
This is a local code exchange; no email or account is required. Both devices need
the exact same app version to pair or sync, including the patch version.
The tray status shows the installed version. Discovery filters mismatches, and
manual IP pairing checks the remote version as well. Pairing confirmation binds
the version into its authenticated transcript, and clipboard messages carry an
authenticated version field. Unversioned older builds are rejected.

Previously saved trust keys are retained, but saved devices are marked offline and do
not receive clipboard content until a versioned, authenticated probe succeeds.
After updating both computers to the same version, their saved keys work again.

Discovery packets advertise a device name and random device ID without encryption.
Device names in the nearby list are untrusted; verify the target before pairing.
Because discovery and pairing hellos are unauthenticated, a version mismatch they
report only hides the nearby entry; only an authenticated frame from a saved device
can mark that device incompatible.

Devices communicate on **TCP and UDP port 45832**, over IPv4 on the local network.
Wi-Fi client isolation, guest networks, VPNs, and firewalls may block communication.
Discovery uses UDP, so seeing a device does not prove its TCP port is reachable.
Pairing exchanges all four messages over the initiating TCP connection; it does
not require a reverse connection. If Mac-to-Windows cannot connect, allow the
current Windows executable on private networks in Windows Firewall, or initiate
pairing from Windows. Clipboard updates in both directions reuse the authenticated connection, so the
initiating computer does not need an inbound firewall exception for that session.
At least one computer must accept inbound TCP port 45832 to establish a connection. Connection errors include the address,
port, and underlying socket error. This transport fix requires updating both apps.
The implementation does not use or interoperate with CrossPaste's wire protocol.

Open the top status/paired-count submenu and select a device's **Forget** entry
to revoke its access locally. Every saved device is listed, including offline or
not-yet-verified ones (marked "offline"), so a lost device can be revoked; forget it
on the other computer too if you want to remove both saved records. Up to 16 peers
can be stored. Groups can relay through paired intermediaries while they are online.

## Sync timing log

No extra tray items are needed. The app keeps the latest 50 log entries in `sync.log` in its data directory:

- macOS/Linux: `~/.clipboard-sync/sync.log`
- Windows: `%LOCALAPPDATA%/ClipboardSync/sync.log`

Watch it live on Mac/Linux with `tail -F ~/.clipboard-sync/sync.log`, or read the latest Windows entries in PowerShell with
`Get-Content "$env:LOCALAPPDATA/ClipboardSync/sync.log" -Tail 50`.
The file is replaced atomically as entries arrive; reopen it when using a viewer
that does not follow file replacements. Close an existing PowerShell
`Get-Content -Wait` session before launching this version: some Windows readers
hold the file open in a way that prevents replacement. Terminal scrollback is separate from the
50-entry file limit and may still show older entries.

Each line has a UTC timestamp with millisecond precision and a local monotonic
`mono_ms` time. For one copy, follow these stages:

1. `copy_detected`: the source notices a new local clipboard value.
2. `send_queued`: the encrypted update is accepted into the outgoing queue;
   `send_failed` means it was not accepted.
3. `sent`: the complete frame has been handed to the local socket. Its
   `elapsed_ms` measures queueing and socket-send time, including retries.
4. `received`: the remote socket has assembled the complete frame.
5. `receive_authenticated`: the receiver accepts/decrypts the clipboard update.
6. `clipboard_written`: the native clipboard write succeeds; `elapsed_ms` is
   local processing time from handing the frame to the app through the write.
   A failure instead records `clipboard_write_failed`; the newest failed update is
   retried every 250 ms for about 2.5 seconds (logging `clipboard_written` or
   `clipboard_write_abandoned`) unless a newer copy supersedes it. A frame whose
   replay counter was already accepted records `receive_replayed` and is ignored.

Match `event` IDs across devices and relays. Match `wire` IDs between a
`send_queued`, `sent`, `received`, and authenticated receipt for an individual
network hop. Socket-stage rows use `event=-`, `kind=0`, and encrypted frame size;
app-stage rows use clipboard kind (1=text, 2=file) and payload size. Routine outgoing
control probes and their connection retries are omitted to keep clipboard activity
visible. Incoming socket entries may still include control traffic; a clipboard
update also has a nonzero event ID in `receive_authenticated`. Only one unsent
control frame is retained per connection, and discovery keeps using a healthy
authenticated endpoint rather than probing its alternate network interfaces. Skipped paused, duplicate, or already-current
updates have explicit entries. `sent` confirms local socket acceptance, not remote
delivery; use the receiver's entries to establish delivery.

Cross-device timestamp differences depend on clock alignment. Use `mono_ms`
differences within one process for local timing; these clocks cannot be compared
between computers. Windows reacts to clipboard-change notifications, with polling every 200 ms as
fallback. Mac/Linux normally poll every 200 ms. Time before `copy_detected` is not
included in its timestamp. On Windows, `clipboard_change_notified` and
`clipboard_read_started`/`clipboard_read_complete` expose time spent obtaining
source data (including delayed rendering by the source app). `clipboard_read_busy`
means another application held the clipboard; the read is retried. A transient
unavailable data handle is also retried. `connection_retry_scheduled` explains a
three-second outgoing connection retry wait; match its `wire` to the queued frame.
Idle authenticated connections start a fresh I/O timeout when a new copy is queued,
so merely idling over ten seconds no longer causes a reconnect before sending. An open native tray menu may keep its displayed
history until reopened even while the clipboard and log continue updating.

Logs contain metadata (peer IP, random event/packet IDs, sizes and timing), never
clipboard text, file contents/names, secrets, or pairing codes. The file keeps at most 50 entries (no rotating backup).
Same-version restarts retain the recent entries. Deleting or emptying `sync.log`
also clears its in-memory history on the next logged event, so old lines are not
restored. The first launch of a different
version clears the log and removes any legacy `sync.log.1` backup; a `log-version`
marker tracks that transition. Clearing on upgrade is a temporary debugging choice
that intentionally gives up history from the previous release. Version 0.2.7 must
be installed on both devices because connections require matching versions.

## Data and current limits

- Trusted-device secrets: `~/.clipboard-sync/devices.bin` on macOS/Linux;
  `%LOCALAPPDATA%/ClipboardSync/devices.bin` on Windows. POSIX storage is private to
  the current user. Windows inherits the user's LocalAppData permissions. Secrets
  are stored on disk without a keychain wrapper; protect this directory.
- Received files: `transfers/` inside that directory, each in a unique subdirectory.
  Files are never executed. Names are validated against traversal and common
  Windows reserved names. Transfers remain on disk so pasted file URLs stay valid;
  remove old transfer directories manually when no longer needed.
- History clears at quit. Repeated identical copies move to the front instead of
  occupying multiple entries. There is no persistent clipboard database.
- macOS ignores automatic VoiceInk pastes marked `com.VoiceInk.PasteSession`, so
  these temporary dictation writes do not enter history or sync to other devices.
  VoiceInk's regular manual clipboard copies are still handled normally.
- Plain text and individual regular files only: no rich text, images, folders,
  multiple-file copies, or files above the size limit. Unsupported items are ignored.
- Transfers use persistent, authenticated, bidirectional TCP connections. Network
  polling is non-blocking, with bounded work per poll and a 32 MiB aggregate queue.
  Inbound connections that have not yet delivered an authenticated frame share at
  most two maximum-size frames of that queue and 16 connection slots, and are closed
  after 15 seconds plus time proportional to the frame they claim.
  Unsent frames may retry for up to 30 seconds; there is no durable offline queue or
  catch-up merge. Simultaneous copies can race; no distributed ordering is promised.
- Mac and Windows timers keep syncing during menu tracking. Menus retain stable
  history item IDs while new copies arrive. The Mac drains queued UI events and
  rebuilds changed menu content only when opened, rather than replacing its status
  menu every few seconds.
- Pairing is reported as complete after an authenticated follow-up proves the other
  endpoint saved its key. If a previous attempt completed on only one computer,
  generate a new code there and pair again from the other computer; the fresh PIN
  exchange can repair the existing record without clearing all devices.
- Every clipboard frame carries an encrypted, strictly increasing counter. Each device
  saves, per peer, the highest counter accepted and a 64-frame reordering window in
  `devices.bin` before acting on a frame, so replays are rejected even after a restart.
  Outgoing counters are reserved on disk in blocks. Version 0.2.7 migrates older
  `devices.bin` files automatically. Older versions cannot read the new format, so
  downgrading starts with no paired devices.
  This initial custom protocol has not had a security audit and does not provide
  forward secrecy.
- macOS builds include an `.app` bundle. No installers, signing/notarization,
  startup registration, or auto-updates yet.

## Implementation and validation

- `src/version.zig`: the shared app version for networking, tray status, and macOS bundle metadata.
  Bump it for each release; all platforms must use the same value.
- `src/pairing.zig`: six-digit validation/generation and SPAKE2 with an RFC test vector.
- `src/core.zig`: bounded encrypted frames, portable filename validation, hashing,
  and owned ten-item history.
- `src/main.zig`: pairing/trust state, automatic clipboard polling, sync routing,
  event deduplication, and native menu callbacks.
- `src/bridge.zig`: explicit C ABI declarations, with a native layout compatibility test.
- `src/native/common.c`: bounded TCP transport, UDP discovery, private storage, RNG,
  and received-file staging.
- `src/native/macos.m`, `windows.c`, `linux.c`: platform clipboard and tray APIs.
- `tests/mock.c`: deterministic native adapter for integration tests.
- `tests/transport.c`: real loopback transport at minimum and maximum frame sizes.

`zig build test` checks encryption/tampering, filename validation, the 5 MiB boundary,
mutual key confirmation, wrong codes, pairing expiry/attempt limits, sync/relay
behavior, replay suppression, history
restoration, forgetting peers, version-mismatched discovery/direct IP pairing,
and version checks on saved-peer traffic. Socket tests use isolated ephemeral ports and include a two-process pairing
exchange followed by twenty bidirectional clipboard frames and maximum-size file
transfers whose initiating process has no reverse listener. They also verify that
an unreachable destination does not block a send call. CI is configured to build/test natively on all three platforms.

Before relying on a release, test with two physical computers: pair, copy Unicode
text in both directions, restore an older history entry, copy/paste a small ZIP and
compare its SHA-256, reject a file above 5 MiB, pause/resume, forget a peer, restart
both apps, and reconnect after an IP change. Verify the Linux desktop's tray and
file-manager paste behavior separately. Automated tests do not replace these native
OS integration checks.
