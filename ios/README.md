# Memories iOS Wrapper

iOS implementation of the NativeX interface, mirroring the Android wrapper in `../android`.

Note that all code under this tree is licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0.html), unlike Memories itself, which is licensed under the AGPLv3 license.

## Build

- Requires Xcode 16 or newer (the project uses synchronized folders), iOS 16+.
- Open `Memories.xcodeproj`, pick your team under *Signing & Capabilities*, and change the bundle identifier (`gallery.memories.ios`) if needed.
- New files under `Memories/` are picked up automatically; no project edits needed.
- CI builds the app unsigned (`.github/workflows/ios.yaml`).

## Architecture

Same design as Android:

- `Server/`: loopback HTTP server on `127.0.0.1:62079` (Network.framework).
  - Serves the bundled welcome/waiting pages (`Resources/`) and the offline app shell.
  - Proxies everything else to Nextcloud with the stored app password, so the WebView stays same-origin.
  - Requests need a per-launch `local-auth` cookie, set by the `/local/auth` handshake on every top-level load.
- `Assets/`: downloads the signed JS/CSS snapshot from `api/describe?manifest=1` and verifies the DSSE/Ed25519 signature.
- `Bridge/`: `NAPI` routes (`/api/…`, `/image/…`) and the injected `window.nativex`.
  - WKWebView has no synchronous JS → native calls, so sync getters use a synchronous XHR to `/api/nx/…`.
- `Account/`: Nextcloud login flow v2 in an in-app Safari sheet; credentials live in the keychain.
- `Media/`: PhotoKit index in SQLite with the server's `auid`/`buid`/`dayid` formulas.
  - "Folders" are Photos albums: *All Photos*, a few smart albums and every user album.
- `Share/`: share sheet for URLs/files, in-process downloads, WebDAV uploads of local files.

## Differences from Android

- Deleting local files always shows the iOS confirmation; there is no media-management grant (`canManageMedia` is undefined).
- Videos play in the web player; the legacy native player calls are no-ops.
- Downloads open the share sheet (Save to Files / Save Image) instead of writing to a Downloads folder.
