import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/update.dart';
import 'package:airreload/src/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const installedVersion = '0.3.0-beta.2';
const revision = '1234567890123456789012345678901234567890';
String manifest([String version = '0.3.0-beta.3']) =>
    '''
CLI_REPOSITORY=https://github.com/Airreload/cli.git
CLI_TAG=v$version
CLI_COMMIT=$revision
FLUTTER_REPOSITORY=https://github.com/Airreload/flutter.git
FLUTTER_TAG=airreload-flutter-3.47.5-v1-rc.1
FLUTTER_COMMIT=$revision
''';

class TestLogger extends Logger {
  final messages = <String>[];
  @override
  void info(String? message, {LogStyle? style}) => messages.add(message ?? '');
  @override
  void success(String? message, {LogStyle? style}) =>
      messages.add(message ?? '');
  @override
  void err(String? message, {LogStyle? style}) => messages.add(message ?? '');
}

void main() {
  late Directory root;
  late Workspace workspace;
  late TestLogger logger;
  late List<Uri> requests;
  late int installs;
  late DateTime now;
  late String remoteManifest;
  late int installExit;
  String? temporaryPath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('airreload-update-test-');
    workspace = Workspace(root.path);
    await File(p.join(root.path, '.airreload-installer'))
        .writeAsString('airreload-installer-v1\n');
    logger = TestLogger();
    requests = [];
    installs = 0;
    now = DateTime.utc(2026, 9, 25);
    remoteManifest = manifest();
    installExit = 0;
    temporaryPath = null;
  });
  tearDown(() async => root.delete(recursive: true));

  UpdateManager manager({UpdateFetch? fetch, bool supported = true}) =>
      UpdateManager(
        workspace,
        currentVersion: installedVersion,
        logger: logger,
        supported: supported,
        windows: false,
        now: () => now,
        fetch:
            fetch ??
            (uri) async {
              requests.add(uri);
              if (uri.host == 'api.github.com') {
                return jsonEncode({'sha': revision});
              }
              expect(uri.pathSegments, contains(revision));
              if (uri.path.endsWith('versions.env')) return remoteManifest;
              if (uri.path.endsWith('install.sh')) {
                return '#!/usr/bin/env bash\nexit 0\n';
              }
              fail('Unexpected request: $uri');
            },
        install: (script, destination) async {
          installs++;
          temporaryPath = p.dirname(script);
          expect(destination, root.path);
          expect(
            await File(script).readAsString(),
            startsWith('#!/usr/bin/env bash'),
          );
          expect(
            await File(p.join(temporaryPath!, 'versions.env')).readAsString(),
            remoteManifest,
          );
          return installExit;
        },
      );

  test(
    'semantic versions handle beta ordering, stable releases and no downgrades',
    () {
      expect(
        UpdateRelease(
          revision,
          manifest('0.3.0-beta.10'),
        ).newerThan('0.3.0-beta.3'),
        isTrue,
      );
      expect(
        UpdateRelease(revision, manifest('0.3.0')).newerThan('0.3.0-beta.10'),
        isTrue,
      );
      expect(UpdateRelease(revision, manifest()).newerThan('0.3.0'), isFalse);
      expect(
        UpdateRelease(revision, manifest()).newerThan('0.3.0-beta.3'),
        isFalse,
      );
    },
  );

  test(
    'native manifests require hashes without requiring a Flutter runtime',
    () {
      final native =
          '${manifest().split('FLUTTER_REPOSITORY').first}'
          'CLI_DISTRIBUTION=native\n'
          'CLI_SHA256_MACOS_ARM64=${'a' * 64}\n'
          'CLI_SHA256_WINDOWS_X64=${'b' * 64}\n';
      expect(UpdateRelease(revision, native).tag, 'v0.3.0-beta.3');
      for (final invalid in [
        native.replaceFirst('a' * 64, 'invalid'),
        native.replaceFirst('b' * 64, ''),
        native.replaceFirst(
          'CLI_DISTRIBUTION=native',
          'CLI_DISTRIBUTION=unknown',
        ),
      ]) {
        expect(() => UpdateRelease(revision, invalid), throwsFormatException);
      }
    },
  );

  test('rejects malformed and redirected manifests', () {
    for (final invalid in [
      manifest().replaceFirst('Airreload/cli.git', 'someone/cli.git'),
      '${manifest()}CLI_TAG=v1.0.0\n',
      manifest().replaceFirst('CLI_COMMIT=$revision', 'CLI_COMMIT=bad'),
      manifest().replaceFirst('v0.3.0-beta.3', '../../bad'),
    ]) {
      expect(() => UpdateRelease(revision, invalid), throwsFormatException);
    }
    expect(() => UpdateRelease('main', manifest()), throwsFormatException);
    expect(
      UpdateRelease(
        revision,
        manifest('0.3.0+build.2'),
      ).newerThan('0.3.0+build.1'),
      isFalse,
    );
  });

  test(
    'check displays release changes and next step without mutations',
    () async {
      expect(await manager().update(checkOnly: true), 0);
      final output = logger.messages.join('\n');
      expect(output, contains('A newer CLI release'));
      expect(output, contains('/compare/v$installedVersion...v0.3.0-beta.3'));
      expect(
        output,
        contains('Run airreload update to install this release here.'),
      );
      expect(installs, 0);
      expect(requests, hasLength(2));
      expect(await Directory(workspace.state).exists(), isFalse);
    },
  );

  test('update pins installer and manifest to same revision and cleans temporary files', () async {
    expect(await manager().update(), 0);
    expect(installs, 1);
    expect(requests, hasLength(3));
    expect(await Directory(temporaryPath!).exists(), isFalse);
    expect(logger.messages.join(), contains('Updated Airreload to'));
  });

  test('installer failures propagate and clean temporary files', () async {
    installExit = 7;
    expect(await manager().update(), 7);
    expect(await Directory(temporaryPath!).exists(), isFalse);
    expect(logger.messages.join(), isNot(contains('Updated Airreload to')));
  });

  test(
    'real installer subprocess receives the replacement flags and target',
    () async {
      final updater = UpdateManager(
        workspace,
        currentVersion: installedVersion,
        logger: logger,
        supported: true,
        fetch: (uri) async {
          if (uri.host == 'api.github.com') {
            return jsonEncode({'sha': revision});
          }
          if (uri.path.endsWith('versions.env')) return manifest();
          return r'''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --replace && "$2" == --no-path && "$3" == --preserve-data ]]
[[ "$AIRRELOAD_NO_UPDATE_CHECK" == 1 ]]
[[ -f "$AIRRELOAD_INSTALL_ROOT/.airreload-installer" ]]
printf 'updated' >"$AIRRELOAD_INSTALL_ROOT/subprocess-result"
''';
        },
      );
      expect(await updater.update(), 0);
      expect(
        await File(p.join(root.path, 'subprocess-result')).readAsString(),
        'updated',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'Windows stages its pinned installer and reports handoff, not completion',
    () async {
      final updater = UpdateManager(
        workspace,
        currentVersion: installedVersion,
        logger: logger,
        supported: true,
        windows: true,
        fetch: (uri) async {
          requests.add(uri);
          if (uri.host == 'api.github.com') {
            return jsonEncode({'sha': revision});
          }
          expect(uri.pathSegments, contains(revision));
          if (uri.path.endsWith('versions.env')) return manifest();
          expect(uri.path.endsWith('install.ps1'), isTrue);
          return '# pinned PowerShell installer';
        },
        install: (script, destination) async {
          temporaryPath = p.dirname(script);
          expect(p.basename(script), 'install.ps1');
          expect(destination, root.path);
          expect(
            await File(script).readAsString(),
            '# pinned PowerShell installer',
          );
          expect(
            await File(p.join(temporaryPath!, 'versions.env')).readAsString(),
            manifest(),
          );
          return installExit;
        },
      );
      expect(await updater.update(checkOnly: true), 0);
      expect(temporaryPath, isNull);
      expect(await updater.update(), 0);
      expect(logger.messages.join(), contains('separate PowerShell window'));
      expect(logger.messages.join(), isNot(contains('Updated Airreload to')));
      expect(await Directory(temporaryPath!).exists(), isTrue);
      await Directory(temporaryPath!).delete(recursive: true);
      installExit = 7;
      expect(await updater.update(), 7);
      expect(await Directory(temporaryPath!).exists(), isFalse);
    },
  );

  test('Windows x64 is supported by the real platform check', () {
    expect(supportsAutomaticUpdates(), isTrue);
  }, skip: !Platform.isWindows);

  test('PowerShell payload uses UTF-16 and literal quotes for paths', () {
    final script = windowsUpdateScript(
      p.join(root.path, "update ' folder", 'install.ps1'),
      "C:\\Users\\O'Brien \$name ናቲ",
      42,
      pauseOnExit: false,
    );
    expect(script, contains("O''Brien"));
    final bytes = base64Decode(encodePowerShell(script));
    final decoded = String.fromCharCodes([
      for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
    ]);
    expect(decoded, script);
  });

  test(
    'Windows helper waits for its parent, preserves flags, and cleans up',
    () async {
      final powerShell = p.join(
        Platform.environment['SystemRoot']!,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final parent = await Process.start(powerShell, [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Console]::ReadLine() | Out-Null',
      ]);
      addTearDown(() {
        parent.kill();
      });
      final stage = await Directory.systemTemp.createTemp(
        "airreload update ' ",
      );
      addTearDown(() async {
        if (await stage.exists()) await stage.delete(recursive: true);
      });
      final installer = File(p.join(stage.path, 'install.ps1'));
      await installer.writeAsString(
        r'''param([switch]$Replace, [switch]$NoPath, [switch]$PreserveData)
if (-not ($Replace -and $NoPath -and $PreserveData)) { throw 'Missing update flags' }
if ($env:AIRRELOAD_NO_UPDATE_CHECK -ne '1') { throw 'Update recursion not disabled' }
Set-Content -LiteralPath (Join-Path $env:AIRRELOAD_INSTALL_ROOT 'updated') -Value 'done'
''',
      );
      final cache = File(p.join(workspace.state, 'update-check.json'));
      await cache.parent.create(recursive: true);
      await cache.writeAsString('{}');
      final helper = await Process.start(powerShell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodePowerShell(
          windowsUpdateScript(
            installer.path,
            root.path,
            parent.pid,
            pauseOnExit: false,
          ),
        ),
      ]);
      addTearDown(() {
        helper.kill();
      });
      final waiting = Completer<void>();
      final output = <String>[];
      final subscription = helper.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            output.add(line);
            if (line.contains('Waiting for Airreload to exit')) {
              waiting.complete();
            }
          });
      final errors = helper.stderr.transform(utf8.decoder).join();
      await waiting.future.timeout(const Duration(seconds: 30));
      expect(await File(p.join(root.path, 'updated')).exists(), isFalse);
      parent.stdin.writeln('exit');
      await parent.stdin.close();
      expect(
        await helper.exitCode.timeout(const Duration(seconds: 30)),
        0,
        reason: await errors,
      );
      await subscription.cancel();
      expect(
        await File(p.join(root.path, 'updated')).readAsString(),
        contains('done'),
      );
      expect(await stage.exists(), isFalse);
      expect(await cache.exists(), isFalse);
      expect(output.join(), contains('Airreload update completed'));
    },
    skip: !Platform.isWindows,
  );

  test('Windows helper reports installer errors and cleans up', () async {
    final powerShell = p.join(
      Platform.environment['SystemRoot']!,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final stage = await Directory.systemTemp.createTemp(
      'airreload-update-error-',
    );
    addTearDown(() async {
      if (await stage.exists()) await stage.delete(recursive: true);
    });
    final installer = File(p.join(stage.path, 'install.ps1'));
    await installer.writeAsString("throw 'fixture installation failure'");
    final result = await Process.run(powerShell, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encodePowerShell(
        windowsUpdateScript(
          installer.path,
          root.path,
          2147483647,
          pauseOnExit: false,
        ),
      ),
    ]);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('fixture installation failure'));
    expect(result.stdout, isNot(contains('update completed')));
    expect(await stage.exists(), isFalse);
  }, skip: !Platform.isWindows);

  test('equal and newer local versions never install', () async {
    for (final version in [installedVersion, '0.2.0']) {
      remoteManifest = manifest(version);
      expect(await manager().update(), 0);
    }
    expect(installs, 0);
  });

  test('source checkouts can check but cannot be replaced', () async {
    await File(p.join(root.path, '.airreload-installer')).delete();
    expect(await manager().update(checkOnly: true), 0);
    expect(await manager().update(), 1);
    expect(installs, 0);
    expect(logger.messages.join(), contains('rebuild the executable'));
    requests.clear();
    await manager().notifyIfAvailable();
    expect(requests, isEmpty);
  });

  test('unsupported platforms never install', () async {
    expect(await manager(supported: false).update(), 1);
    expect(installs, 0);
  });

  test('active host or run blocks replacement but permits checking', () async {
    for (final location in [
      workspace.session,
      p.join(workspace.state, 'runs', 'run-test', 'session.json'),
    ]) {
      final session = File(location);
      await session.parent.create(recursive: true);
      await session.writeAsString(jsonEncode({'pid': pid}));
      expect(await manager().update(checkOnly: true), 0);
      expect(await manager().update(), 1);
      expect(installs, 0);
      expect(
        logger.messages.join(),
        contains('Stop the running Airreload session'),
      );
      await session.delete();
    }
  });

  test('explicit network failures fail, advisory failures remain silent and cached', () async {
    var calls = 0;
    final updater = manager(
      fetch: (_) async {
        calls++;
        throw const SocketException('offline');
      },
    );
    expect(await updater.update(checkOnly: true), 1);
    expect(logger.messages.join(), contains('offline'));
    logger.messages.clear();
    await updater.notifyIfAvailable();
    await updater.notifyIfAvailable();
    expect(calls, 2);
    expect(logger.messages, isEmpty);
  });

  test('notices cache for one day and explicit checks bypass cache', () async {
    final updater = manager();
    await updater.notifyIfAvailable();
    await updater.notifyIfAvailable();
    expect(requests, hasLength(2));
    expect(
      logger.messages.where((m) => m.contains('update available')),
      hasLength(2),
    );
    expect(logger.messages.join('\n'), contains('airreload update to install'));
    await updater.update(checkOnly: true);
    expect(requests, hasLength(4));
    now = now.add(const Duration(days: 1));
    await updater.notifyIfAvailable();
    expect(requests, hasLength(6));
  });

  test('corrupt cache recovers and current versions do not notify', () async {
    await Directory(workspace.state).create(recursive: true);
    await File(p.join(workspace.state, 'update-check.json'))
        .writeAsString('broken');
    remoteManifest = manifest(installedVersion);
    await manager().notifyIfAvailable();
    expect(requests, hasLength(2));
    expect(logger.messages, isEmpty);
  });
}
