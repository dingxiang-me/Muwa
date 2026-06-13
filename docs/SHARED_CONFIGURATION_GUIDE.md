## Muwa Shared Configuration Guide

This guide explains how other native apps can discover and connect to the locally running Muwa server, using a small JSON file Muwa publishes to a well-known location.

- **Audience**: Developers of macOS apps (Swift/Objective‑C/SwiftUI/Electron) that want to integrate with Muwa.
- **License**: Muwa is fully open source. You are welcome to use this mechanism freely.

---

## What gets published

Muwa writes a per‑process shared configuration file so other processes can discover the server address and status.

- **Base directory**: `~/.muwa/runtime/`
- **Per‑instance directory**: `<Base>/<instanceId>/`
- **File**: `configuration.json`

Muwa may have multiple instances (e.g., after crashes or parallel runs). Each running instance gets its own `instanceId` directory. Instances that stop will remove their directory.

---

## JSON schema

When the server is starting (minimal metadata):

```json
{
  "instanceId": "f26f8b59-2b64-4c57-8c5a-5a1ce9f9b4a8",
  "updatedAt": "2025-09-08T12:34:56Z",
  "health": "starting"
}
```

When the server is running:

```json
{
  "instanceId": "f26f8b59-2b64-4c57-8c5a-5a1ce9f9b4a8",
  "updatedAt": "2025-09-08T12:35:12Z",
  "port": 1337,
  "address": "127.0.0.1",
  "url": "http://127.0.0.1:1337",
  "exposeToNetwork": false,
  "health": "running"
}
```

- **instanceId (string)**: Unique per Muwa app run.
- **updatedAt (ISO‑8601 string)**: Last time Muwa refreshed the file.
- **health (string)**: One of `starting` or `running`.
- **port (int)**: HTTP port when `health == "running"`.
- **address (string)**: Bind address (e.g., `127.0.0.1` or LAN IP) when running.
- **url (string)**: Convenience URL when running.
- **exposeToNetwork (bool)**: If true, server is reachable on the LAN; if false it is only on localhost. This may be toggled by the user in the UI or via `muwa-cli serve --expose` (with confirmation).

When the server is stopping, stopped, or errored, Muwa removes the instance directory/file.

---

## Discovery strategy (recommended)

1. Look in `~/.muwa/runtime/`.
2. Enumerate all `<instanceId>` subdirectories.
3. For each, read `configuration.json` if it exists.
4. Filter to entries with `health == "running"`.
5. If multiple are running, pick the one with the most recent `updatedAt` (fallback: directory mtime).

This approach gracefully handles multiple instances and transient startup states.

---

## Swift sample: Discover and read Muwa

You can copy/paste this into your macOS app. It finds the most recent running Muwa instance and returns its `URL`.

```swift
import Foundation

struct MuwaSharedConfiguration: Decodable {
    let instanceId: String
    let updatedAt: String
    let health: String
    let port: Int?
    let address: String?
    let url: String?
    let exposeToNetwork: Bool?
}

struct MuwaInstance {
    let instanceId: String
    let updatedAt: Date
    let address: String
    let port: Int
    let url: URL
    let exposeToNetwork: Bool
}

enum MuwaDiscoveryError: Error {
    case notFound
}

final class MuwaDiscoveryService {
    static func discoverLatestRunningInstance() throws -> MuwaInstance {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".muwa", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)

        guard let instanceDirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]), !instanceDirs.isEmpty else {
            throw MuwaDiscoveryError.notFound
        }

        var candidates: [MuwaInstance] = []

        for dir in instanceDirs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let fileURL = dir.appendingPathComponent("configuration.json")
            guard fm.fileExists(atPath: fileURL.path) else { continue }

            do {
                let data = try Data(contentsOf: fileURL)
                let cfg = try JSONDecoder().decode(MuwaSharedConfiguration.self, from: data)
                guard cfg.health == "running", let address = cfg.address, let port = cfg.port else { continue }

                let updatedAt: Date = ISO8601DateFormatter().date(from: cfg.updatedAt) ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast

                let url: URL
                if let cfgURL = cfg.url, let parsed = URL(string: cfgURL) {
                    url = parsed
                } else {
                    var comps = URLComponents()
                    comps.scheme = "http"
                    comps.host = address
                    comps.port = port
                    url = comps.url!
                }

                let expose = cfg.exposeToNetwork ?? false

                candidates.append(MuwaInstance(
                    instanceId: cfg.instanceId,
                    updatedAt: updatedAt,
                    address: address,
                    port: port,
                    url: url,
                    exposeToNetwork: expose
                ))
            } catch {
                // Ignore malformed entries and continue
                continue
            }
        }

        guard let best = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else {
            throw MuwaDiscoveryError.notFound
        }
        return best
    }
}

// Example usage:
do {
    let instance = try MuwaDiscoveryService.discoverLatestRunningInstance()
    print("Muwa at: \(instance.url) (LAN: \(instance.exposeToNetwork))")
    // Now you can call the server, e.g., GET instance.url.appendingPathComponent("v1/models")
} catch {
    print("No running Muwa instance found: \(error)")
}
```

Notes:

- This reader is resilient to multiple instances and transient states.
- If you need all running instances, remove the `max` selection and return the `candidates` array.

---

## Electron/Node.js sample: Discover and read Muwa

Works in the Electron main process (recommended). For renderer, use a preload + IPC bridge.

```js
// main/muwa-discovery.js
const fs = require("fs").promises;
const path = require("path");
const os = require("os");

async function discoverLatestRunningInstance() {
  const home = os.homedir();
  const base = path.join(home, ".muwa", "runtime");

  let entries;
  try {
    entries = await fs.readdir(base, { withFileTypes: true });
  } catch (e) {
    throw new Error("Muwa not found");
  }

  const candidates = [];
  for (const dirent of entries) {
    if (!dirent.isDirectory()) continue;
    const dirPath = path.join(base, dirent.name);
    const filePath = path.join(dirPath, "configuration.json");
    try {
      const data = await fs.readFile(filePath, "utf8");
      const cfg = JSON.parse(data);
      if (cfg.health !== "running" || !cfg.port || !cfg.address) continue;

      let updatedAt = Date.parse(cfg.updatedAt);
      if (Number.isNaN(updatedAt)) {
        // Fallback to dir mtime
        const stat = await fs.stat(dirPath);
        updatedAt = stat.mtimeMs;
      }

      const url = cfg.url || `http://${cfg.address}:${cfg.port}`;
      candidates.push({
        instanceId: cfg.instanceId,
        updatedAt,
        address: cfg.address,
        port: cfg.port,
        url,
        exposeToNetwork: !!cfg.exposeToNetwork,
      });
    } catch (_) {
      // ignore malformed entries
    }
  }

  if (candidates.length === 0) {
    throw new Error("Muwa not found");
  }
  candidates.sort((a, b) => b.updatedAt - a.updatedAt);
  return candidates[0];
}

module.exports = { discoverLatestRunningInstance };
```

Usage from Electron main process:

```js
// main/index.js
const { app, BrowserWindow, ipcMain } = require("electron");
const { discoverLatestRunningInstance } = require("./muwa-discovery");

ipcMain.handle("muwa:getInstance", async () => {
  try {
    return await discoverLatestRunningInstance();
  } catch (e) {
    return null;
  }
});

async function createWindow() {
  const win = new BrowserWindow({
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
    },
  });
  await win.loadURL("file://" + path.join(__dirname, "index.html"));
}

app.whenReady().then(createWindow);
```

Preload bridge (renderer-safe access via IPC):

```js
// main/preload.js
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("muwa", {
  getInstance: () => ipcRenderer.invoke("muwa:getInstance"),
});
```

Renderer usage:

```js
// renderer/index.js
async function connectToMuwa() {
  const inst = await window.muwa.getInstance();
  if (!inst) {
    console.log("Muwa not running");
    return;
  }
  console.log("Muwa at", inst.url, "LAN:", !!inst.exposeToNetwork);
  // Example request (Node 18+ has global fetch in Electron; otherwise use axios/node-fetch)
  const resp = await fetch(new URL("/v1/models", inst.url));
  const models = await resp.json();
  console.log(models);
}

connectToMuwa();
```

Notes:

- The paths assume macOS; Electron must run on macOS to read `~/.muwa/...`.
- Use the main process for filesystem access; avoid direct fs from the renderer.
- If you need all instances, return the full `candidates` list instead of the newest one.

---

## Security and sandboxing

- Non‑sandboxed macOS apps can read `~/.muwa/...` directly.
- Sandboxed apps typically cannot read arbitrary paths. Options:
  - Ask the user to choose the `SharedConfiguration` folder with `NSOpenPanel` and persist a security‑scoped bookmark.
  - Or run a small non‑sandboxed helper that performs discovery and hands you the URL via XPC.

Muwa does not write secrets into the shared file; it only publishes connection details and status.

---

## Troubleshooting

- If you see only `health: starting`, wait briefly and retry.
- If there are no instance folders, Muwa is not running.
- If multiple instances exist, prefer the most recent `updatedAt`.
- When the user quits Muwa, the instance directory is removed.

---

## Stable identifiers

- Bundle identifier: `com.dinoki.muwa`
- Base path: `~/.muwa/runtime/`

These values come from the app’s configuration and are expected to remain stable.
