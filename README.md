# Airreload CLI

Airreload builds a Flutter Android debug APK, serves it over the local network,
and attaches the Flutter tool for hot reload after the app opens.

> **Beta:** The current version is `0.3.0-beta.7`, with Flutter app logs in the terminal.

## Requirements

- macOS, Linux, or Windows
- Git
- An Android device on the same trusted network as the development computer, with Airreload Go installed
- A standalone Flutter app with a top-level `main` function under `lib/`
- Airreload manages its own Flutter SDKs; no separate project Flutter or FVM installation is required. Android build tools and a suitable JDK are still required.

Pub workspaces and add-to-app modules are not supported.

## Set up from source

Building from source requires Dart 3.13 or later. Flutter is downloaded on demand
when you first run Airreload in a project.

```sh
git clone https://github.com/Airreload/cli.git
cd cli
dart pub get
dart compile exe bin/airreload.dart -o bin/airreload
./bin/airreload doctor
```

On Windows, use `dart compile exe bin/airreload.dart -o bin/airreload.exe`
and `.\bin\airreload.exe doctor`. Keep the executable in `cli/bin` for source
checkouts. The public installer places the native executable in
`~/.airreload/bin` (or `%USERPROFILE%\.airreload\bin`) and needs no Dart or Flutter
installation. See the [installer](https://github.com/Airreload/installer).

## Optional CLI analytics

Airreload's own telemetry is **enabled by default**. View or change it at any time:

```sh
airreload telemetry status
airreload telemetry disable
airreload telemetry enable
```

The preference is stored per installation in `cli/.airreload/telemetry.json`.
The first tracked run creates a random installation ID and prints a short notice
with the disable command. Explicitly enabling also creates an ID; disabling removes it. Enabling again
after disabling creates a new ID. Disabling does not delete previously received
events from PostHog. Help, version, status, and telemetry controls send no events.
`AIRRELOAD_TELEMETRY_DISABLED=1`, `DO_NOT_TRACK=1`, or `CI=true`/`CI=1` overrides
the saved preference and the enabled default, without creating an ID. A missing
preference uses the enabled default; unreadable or invalid existing settings
disable collection. Existing opt-outs are preserved.

Only `airreload run` emits these explicit events:

| Event | Meaning | Additional fields |
| --- | --- | --- |
| `cli_run_started` | Run command entered | None |
| `cli_phone_paired` | Phone pairing completed | Flutter version |
| `cli_build_succeeded` | Debug APK ready to download | Flutter version, build duration |
| `cli_app_connected` | First responsive app VM connection in this run | Flutter version, time since run start |
| `cli_run_ended` | Run completed, was cancelled, or failed | Flutter version when known, last stage, outcome, elapsed duration |

Common fields are event timestamp, random installation ID, `surface=cli`, CLI
version, and operating-system name. Stages and outcomes are fixed categories.
Events never include source code, project names/paths, command arguments,
environment variables, pairing tokens, app logs, or raw errors. Collection uses
HTTPS to Airreload's US PostHog project; person profiles and GeoIP enrichment are
disabled in the payload. The receiving server still sees the connection IP.
Configure PostHog's project-level IP discard setting before collecting real usage.

Sending happens in the background, with a one-second request deadline, at most
four concurrent requests and 64 events per invocation. No disk queue, retries,
redirects, session replay, or automatic event capture is used. Normal command
shutdown waits at most 250 ms for pending requests. Network failures silently
drop events. Active processes recheck the saved preference before each send; an already
transmitted request cannot be recalled. Opt-outs and best-effort delivery mean
these metrics describe participating installations, not all users or downloads.
An app connection is **not** a successful hot reload. Individual reloads are not
measured yet because Flutter owns the interactive attach process.

### PostHog configuration for maintainers

The bundled `phc_` project token is intentionally public and grants no access to
private analytics. Never put personal (`phx_`) or secret (`phs_`) keys in the CLI.
Runtime environment variables `AIRRELOAD_POSTHOG_TOKEN` and
`AIRRELOAD_POSTHOG_REGION` (`us` or `eu`) override the defaults. These values can
also be overridden at compilation using Dart `-D` options; saved opt-outs and
environment overrides still take precedence. Invalid tokens/regions disable collection. Test suites use
a synthetic token and a local HTTP server, never the production project.

Use the free PostHog plan or set a billing limit. A public token can be abused
to submit fake events; do not use this telemetry as proof of identity or for
billing. The `cli_telemetry_test` event is reserved for manual integration checks
and should be excluded from usage dashboards.

## Waiting and reconnecting

`airreload run` keeps its pairing code, download server, and app connection
available until you stop the session with Ctrl-C. Waiting to scan, a slow first
build, or taking time to install the APK does not expire the session by default.
To limit each pairing/connection wait, pass `--wait-timeout 600` (seconds).
The default, `--wait-timeout 0`, disables that deadline. Keep the computer awake
and the terminal running; after stopping or restarting, use the new QR code.

The reconnect hotfix adds **Show reconnect QR** to the
computer's page while building and after the APK is ready. With the corresponding
Airreload Go update, the paired phone can tap **Reconnect to computer** or rescan
that code after returning to the same Wi-Fi. The existing build continues, and
a finished APK is returned without rebuilding. This requires the original CLI
session and network address to remain available; a different phone needs a new
session.

## Updates

```sh
airreload update --check  # Preview the available release and destination
airreload update          # Install it into the current Airreload installation
```

The check shows your installed and available CLI versions, a link to the changes,
the official release source, and the exact installation directory. An update is
suggested only when the CLI version pinned in the official
[installer manifest](https://github.com/Airreload/installer/blob/main/versions.env)
is newer, using semantic version ordering (including beta versions). It does not
select arbitrary GitHub tags or downgrade a newer local version. The installer
manifest defines the published channel, which currently includes beta releases.

Interactive `run` and `doctor` commands check at most once every 24 hours for
installer-owned installations. Results and failed attempts are cached in
`cli/.airreload/update-check.json`; network failures do not stop development.
Help, version, other commands, and non-interactive invocations do not check.
Set `AIRRELOAD_NO_UPDATE_CHECK=1` to disable automatic checks. An explicit
`airreload update --check` always contacts the release source and returns a
nonzero exit code if it cannot check; finding an update still returns zero.

Automatic installation supports installer-owned macOS Apple Silicon and Windows x64 installations.
It updates the native CLI at the current installation
path (normally `~/.airreload`), leaving shell profiles unchanged. The installer
and manifest are fetched from the same immutable installer commit; the installer
verifies the binary against the SHA-256 pinned in the manifest, stages and validates the replacement,
and rolls back on failure. Pairing state and downloaded project SDKs are preserved.
Stop running Airreload sessions before updating. Afterward, use `airreload run`
to rebuild and install a fresh debug APK if the native integration has changed.
Airreload Go on your phone is updated separately.

On Windows, updating opens a separate PowerShell window. The current CLI exits
before the installer replaces the locked executable. Wait for the update window
to confirm success, then run `airreload version`. The helper preserves SDKs and
pairing data, leaves PATH unchanged, and uses the same pinned installer snapshot
and checksum checks as macOS.

Windows CLI versions through `0.3.0-beta.4` only support automatic installation
on macOS. Upgrade those Windows installations using the installer directly:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Airreload/installer/main/install.ps1').Content)) -Replace -PreserveData -NoPath
airreload version
```

Stop running Airreload sessions first. This command replaces only an installation
owned by the installer and preserves its downloaded SDKs and pairing data.


Source checkouts on all platforms can use `update --check`. They receive manual
checkout/dependency/rebuild guidance; `update` will not replace a source checkout.
Older installations without this command need one manual installer replacement
to acquire it: pull the updated installer and run
`./install.sh --replace --preserve-data`.

## Run

From the CLI repository:

macOS/Linux:

```sh
./bin/airreload run --project /path/to/flutter-app
```

Windows PowerShell:

```powershell
.\bin\airreload.exe run --project C:\path\to\flutter-app
```

### Select a Flutter version

The preview supports Flutter **3.47.5, 3.44.9, 3.41.9, and 3.38.10**.
To test an exact version, run:

```sh
airreload run --flutter-version 3.38.10
```

This overrides FVM and installed Flutter for the run. An unavailable version
fails without falling back. Project dependency constraints still apply.
Without the flag, Airreload checks FVM configuration first, then a configured
VS Code SDK or Flutter on PATH. If the exact version is unavailable, Airreload
automatically picks the closest compatible supported version and reports the
decision. If no Flutter version is detected, it picks the latest compatible
supported version.

Airreload downloads an immutable, commit-verified SDK release on first use and
reuses it from the installation's `sdks/` directory. The compiled CLI runs independently
of the selected Flutter SDK. Your project's FVM
configuration and source files are unchanged. These are preview releases for
manual phone acceptance testing.

Scan the displayed QR code in Airreload Go and confirm pairing. Go reports the
phone's Android ABI list (no USB debugging or developer options are needed),
then the CLI builds the best Flutter target: `arm64-v8a`, then `armeabi-v7a`,
then `x86_64`. Go automatically downloads the result after pairing; approve
Android's normal install screen, then open the app. In the terminal, press `r` for hot
reload, `d` to detach, or `q` to quit.

The pairing QR is short-lived, permits one phone, and contains a high-entropy
secret. It uses HTTP only on the local development network because Go must
pair before the newly built APK can pin Airreload's session certificate. Treat
it as you would any trusted-LAN development workflow. The session tunnel in
the installed app remains TLS-authenticated, and the APK endpoint serves only
the session's single, unguessable artifact route.

Run `./bin/airreload help run` for build options. Dart changes under `lib/` can
hot reload; re-run the command after changing assets, dependencies, or native
code. Press `R` for hot restart.

If you close the app on the phone, keep the terminal open and reopen the app.
Airreload verifies the new process's VM service before attaching again and
discards tunnels pointing at a stale VM. After updating Airreload's native
runtime, run a fresh pairing/build and install the new debug APK once.

## Flutter app logs

Once your app connects, `airreload run` displays Dart stdout and stderr in the
terminal, including `print()`, `debugPrint()`, and errors written to stderr.
Logging stays active across hot restart and resumes when the app reconnects.
Logs emitted before attachment are not replayed. Native Android Logcat output
and structured `dart:developer.log()` events are not forwarded to the terminal;
use DevTools for structured Dart logging.

## Contributing

Open an issue before making a large change. For code changes, run:

```sh
dart format --set-exit-if-changed bin lib test tool
dart analyze --fatal-infos
dart test
```

Pull requests run the same checks and compile/smoke-test a native executable on
macOS, Linux, and Windows.

## License

Except where otherwise noted, Airreload CLI is dual-licensed under the
[Apache License, Version 2.0](LICENSE-APACHE) or the [MIT license](LICENSE-MIT),
at your option (`Apache-2.0 OR MIT`).

See [COPYRIGHT](COPYRIGHT) for the copyright notice. Third-party components
retain their respective licenses and copyright notices.
