# Airreload CLI

Airreload builds a Flutter Android debug APK, serves it over the local network,
and attaches the Flutter tool for hot reload after the app opens.

> **Beta:** The current version is `0.2.0-beta.1`.

## Requirements

- macOS or Linux
- Git and OpenSSL
- An ARM64 Android device on the same network as the development computer
- A standalone Flutter app with a top-level `main` function under `lib/`
- The [Airreload Flutter fork](https://github.com/Airreload/flutter) at commit
  `558d79bc24bfcadeff45b93a7d971ae670a1e8fc`

Pub workspaces and add-to-app modules are not supported.

## Set up from source

Keep the Flutter and CLI repositories next to each other:

```text
airreload/
├── cli/
└── flutter/
```

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

The compiled executable must remain at `cli/bin/airreload` in this layout.

## Run

From the CLI repository:

```sh
./bin/airreload run --project /path/to/flutter-app
```

Scan the displayed QR code with the Android phone, install the APK, and open
the app. In the terminal, press `r` for hot reload, `d` to detach, or `q` to
quit.

Run `./bin/airreload help run` for build options. Dart changes under `lib/` can
hot reload; re-run the command after changing assets, dependencies, or native
code. Hot restart is not supported.

## Contributing

Open an issue before making a large change. For code changes, run:

```sh
../flutter/bin/dart format --set-exit-if-changed bin lib test
../flutter/bin/dart analyze --fatal-infos
../flutter/bin/dart test
```
