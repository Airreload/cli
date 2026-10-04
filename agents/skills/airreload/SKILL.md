---
name: airreload
description: Run a developer's Flutter Android app with Airreload and Airreload Go over a local network. Use for Airreload setup, pairing, hot reload, hot restart, reconnection, and troubleshooting; not for developing Airreload itself or production over-the-air updates.
---

# Use Airreload with a Flutter app

## Step 1: Check installation and compatibility

1. Locate the executable with `command -v airreload` on macOS/Linux or `Get-Command airreload` in PowerShell. Run:
   ```sh
   airreload version
   airreload help run
   airreload doctor
   ```
   Use this executable's help for supported options, Flutter versions, and defaults. A source checkout or README may describe a newer CLI. `doctor` checks local tools and SDK state; it does not verify the full Android build environment or phone connectivity.
2. Identify the developer's app directory, `pubspec.yaml`, `android/`, and intended entrypoint. It must be a standalone Flutter Android app with a declared top-level `main` under `lib/`. Supported signatures are `main()` and `main(List<String> args)`. Pub workspaces and add-to-app modules are unsupported. Clarify the app if several are plausible.
3. Check Git, Android build tools, and a suitable JDK. Airreload downloads and caches its own patched Flutter SDK on demand; the native CLI does not require a separate Flutter or FVM installation.
4. The phone needs Airreload Go and a network connection to the computer on the same trusted LAN or hotspot. USB debugging, Android wireless debugging, and ADB pairing are not required.

If installation is missing, consult the official [installer](https://github.com/Airreload/installer) and [Airreload Go](https://github.com/Airreload/airreload-go) instructions for current host/Android requirements and downloads. Do not guess supported installer platforms or release assets. For CLI details, see the [public README](../../../README.md).

## Step 2: Run the app

From the developer's Flutter app directory:

```sh
airreload run
```

Use `--project` when running from another directory. Select options from the app's existing configuration and installed CLI help:

| Option | Purpose |
| --- | --- |
| `--project PATH` | Flutter app directory |
| `--target lib/main_dev.dart` / `-t` | Existing entrypoint under the app's `lib/` |
| `--flavor dev` | Existing Android product flavor |
| `--dart-define=KEY=VALUE` | Definition passed to both build and attach; repeat as needed |
| `--dart-define-from-file=config/dev.json` | Definitions file relative to the app directory; repeat as needed |
| `--flutter-version VERSION` | Exact supported Flutter release, with no fallback |
| `--host LAN_IPV4` | Reachable computer LAN IPv4 when automatic address selection is wrong |
| `--wait-timeout SECONDS` | Pairing/connection wait limit; check help for the default and whether `0` disables it |

Example, only when these paths and flavor exist:

```sh
airreload run --project "../my_flutter_app" --target lib/main_dev.dart --flavor dev --dart-define=ENV=dev --dart-define-from-file=config/dev.json
```

Without an explicit Flutter version, Airreload checks FVM configuration, then a configured VS Code SDK or Flutter on PATH. When the detected release is unavailable, it chooses the closest compatible supported release; with no detected version, it chooses the latest compatible supported release. Read the reported selection and dependency errors. Do not rewrite FVM configuration or relax project constraints to hide a mismatch.

When running on the user's behalf, use a persistent interactive terminal/PTY, retain its process handle, and expose the local pairing page or terminal QR. Keep this session running rather than starting another one for each progress check. Do not pass arbitrary `flutter run` flags to Airreload.

## Step 3: Pair, install, and open

Guide the user through the next phone action as each stage becomes ready:

1. Open Airreload Go, scan the pairing QR or paste its pairing link, then tap **Pair and download**. Go accepts pairing links, not ordinary URLs or direct APK links.
2. Wait for the build and automatic download. The CLI waits for Go's ABI report before building the appropriate debug APK; no build before pairing is expected.
3. Allow Go as an installation source if Android prompts, approve **Install**, and open the installed Flutter app.
4. Leave the computer terminal running while the app connects and Flutter attaches automatically.

Ask the user to perform phone actions when device control is unavailable. Distinguish build, download, Android installation, app connection, and Flutter attachment; success at one stage does not prove the next. Keep pairing links, QR codes, download URLs, and authenticated debug URLs out of shared logs and reports.

## Step 4: Edit and manage the session

Edit the original project's Dart files under `lib/`. Airreload prepares a private build copy linked to those files and generates the debug integration itself; ordinary setup needs no added package, transport code, or manual manifest edits.

After saving, send keys to the attached Airreload terminal, not to a shell prompt:

| Key | Action |
| --- | --- |
| `r` | Hot reload; normally preserves application state |
| `R` | Hot restart; restarts Dart application state |
| `d` | Detach Flutter |
| `q` | Quit the attached Flutter session |
| Ctrl-C | Stop Airreload |

Read reload/restart output and report compilation failures. Claim visible app changes only when observed or confirmed by the user. Keep the terminal available if the user wants to continue developing; when shutdown is requested, stop the owned session and verify that it exits.

**Rebuild and reinstall:** Asset, dependency, or Android/native changes require a fresh `airreload run` and installation of its APK. Also start a new run for changed build options or updated native integration. Dart changes under `lib/` can reload; use hot restart for changes requiring application initialization to run again.

**Reconnect:** If the app closes, preserve the CLI process and reopen the installed app. With compatible Go/CLI versions, the paired phone can return to the same Wi-Fi and tap **Reconnect to computer**, or scan **Show reconnect QR** on the computer's page. The original process and network address must remain available; its build or finished APK can be reused.

**New session:** Restarting the CLI or using a different phone requires new pairing. Install the new session's APK: the previous APK contains the previous session's configuration. Do not restart a healthy session merely because pairing, building, or installation takes time.

## Step 5: Diagnose and verify

Use [troubleshooting.md](references/troubleshooting.md) for SDK selection, build, network, installation, and reload failures. Diagnose from the active run's first relevant error. Manual `host`, `pair`, `status`, and `attach` commands are separate compatibility workflows; `status` does not reliably report a `run` session.

Report the stage reached, selected Flutter version, terminal location if still running, and next required phone action. Do not claim end-to-end hot reload from `doctor` or build success alone.
