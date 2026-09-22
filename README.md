# Airreload CLI

Airreload builds a Flutter Android debug APK, serves it over the local network,
and attaches the Flutter tool for hot reload after the app opens.

> **Beta:** The current version is `0.3.0-beta.1`.

## Requirements

- macOS, Linux, or Windows
- Git
- An Android device on the same trusted network as the development computer, with Airreload Go installed
- A standalone Flutter app with a top-level `main` function under `lib/`
- Airreload manages its own Flutter SDKs; no separate project Flutter or FVM installation is required. Android build tools and a suitable JDK are still required.

Pub workspaces and add-to-app modules are not supported.

## Set up from source

Keep the Flutter and CLI repositories next to each other:

```text
airreload/
├── cli/
└── flutter/
```

### macOS and Linux

```sh
mkdir airreload && cd airreload
git clone https://github.com/Airreload/flutter.git
git -C flutter checkout 558d79bc24bfcadeff45b93a7d971ae670a1e8fc
git clone https://github.com/Airreload/cli.git
cd cli
../flutter/bin/dart pub get
../flutter/bin/dart compile exe bin/airreload.dart -o bin/airreload
./bin/airreload doctor
```

### Windows PowerShell

```powershell
mkdir airreload
cd airreload
git clone https://github.com/Airreload/flutter.git
git -C flutter checkout 558d79bc24bfcadeff45b93a7d971ae670a1e8fc
git clone https://github.com/Airreload/cli.git
cd cli
..\flutter\bin\dart.bat pub get
..\flutter\bin\dart.bat compile exe bin\airreload.dart -o bin\airreload.exe
.\bin\airreload.exe doctor
```

The compiled executable must remain at `cli/bin/airreload` on macOS/Linux or
`cli\bin\airreload.exe` on Windows in this layout.

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
VS Code SDK or Flutter on PATH. If the exact version is unavailable, it asks
before using an alternative and remembers the choice for that project/version.
Noninteractive runs must supply the suggested explicit version.

Airreload downloads an immutable, commit-verified SDK release on first use and
reuses it from the installation's `sdks/` directory. The CLI keeps its own Dart
runtime; selecting an older Flutter never replaces it. Your project's FVM
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

## Contributing

Open an issue before making a large change. For code changes, run:

```sh
dart format --set-exit-if-changed bin lib test tool
dart analyze --fatal-infos
dart test
```

Pull requests run the same checks and compile/smoke-test a native executable on
macOS, Linux, and Windows.
