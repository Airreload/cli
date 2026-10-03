# Troubleshooting by observed stage

Collect the command, CLI version, selected Flutter version, host OS, and first relevant error. Keep authentication material out of shared excerpts. Fix the actual failure before retrying; repeated restarts discard otherwise usable sessions.

| Symptom | Diagnosis and next step |
| --- | --- |
| `airreload` is missing | Resolve PATH and installation location. Open a fresh terminal after installation; consult the official [installer](https://github.com/Airreload/installer) if installation is absent. |
| `doctor` succeeds but Android build fails | Read Flutter/Gradle's first error. Check Android SDK, licenses, JDK compatibility, and dependencies as indicated. `doctor` is not an end-to-end build check. |
| Waiting for Go; no build starts | Pair in Go first. The CLI waits for the phone's ABI report before choosing an APK architecture. |
| QR/manual link rejected | Use the active `run` pairing link. Direct APK links and unrelated URLs are rejected intentionally. If the process restarted, scan its new QR. |
| Phone cannot reach computer | Check the shared network, advertised computer IPv4, VPN routing, guest/client isolation, and application firewall rules. Use `--host` with a verified reachable computer LAN IPv4. Loopback/localhost points to the phone itself. Do not disable the firewall globally. |
| Phone disconnects during build | Preserve the original CLI process and network address. On compatible releases, use **Reconnect to computer** or **Show reconnect QR**. A slow build alone is not a reason to restart. |
| Wait timeout | Consult this executable's `help run`. Current versions accept `--wait-timeout 0` for indefinite waits; older versions have different defaults. Restart after the session actually ends or recovery requires it. |
| Unsupported Flutter version/constraints | Compare supported versions in help with project SDK constraints. Explicit `--flutter-version` has no fallback. Automatic selection may choose a nearby compatible release. Do not alter FVM or loosen constraints without a project reason. |
| SDK acquisition/bootstrap fails | Inspect download and commit-validation diagnostics. A long Windows cache path may require a shorter installation root. Preserve other cached SDKs; do not clear the entire installation or bypass integrity checks. |
| Unsupported app/entrypoint | Check for a standalone Android app and a Dart file under `lib/` declaring top-level `main()`, or a supported one-positional-argument main. Pub workspaces and add-to-app modules are unsupported. |
| Flavor, definitions, or Gradle file missing | Match the app's established flavor/entrypoint and definition files. Definition-file paths are relative to the original app. The private build copy does not rewrite arbitrary external Gradle references; inspect the specific failed reference. |
| Unsupported ABI | Supported choices are `arm64-v8a`, `armeabi-v7a`, and `x86_64`; x86-only devices cannot use this workflow. Let Go report ABIs. |
| Download succeeds, app not connected | Complete Android installation and open the generated Flutter app. Go is the downloader/installer, not the app Flutter attaches to. Confirm the APK belongs to the current session. |
| Android rejects installation | Use Android's message to distinguish permission, storage, signature, or downgrade failures. Do not uninstall an existing app as a routine workaround; it can remove its data. |
| App closes or connection drops | Keep the CLI running and reopen the app. Check network reachability. If the CLI or its address changed, start a new session and install its APK. |
| Source edits do not appear | Save the original app's `lib/` files, confirm target/flavor, and send `r` to the attached terminal. Read compilation errors. Use `R` when restart is needed. Asset, dependency, and native changes require a new run/build/install. |
| `status` says host offline during `run` | `status` queries separate manual-host state. Use the active run's output and pairing page; do not start a second manual host to repair it. |

Keep verification claims specific: SDK acquisition, APK build, Go download, Android installation, app connection, Flutter attachment, hot reload, and hot restart are separate milestones. State which were observed and which still require phone confirmation.
