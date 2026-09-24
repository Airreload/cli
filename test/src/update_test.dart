import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/update.dart';
import 'package:airreload/src/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const revision = '1234567890123456789012345678901234567890';
String manifest([String version = '0.3.0-beta.2']) =>
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
        logger: logger,
        supported: supported,
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
        ).newerThan('0.3.0-beta.2'),
        isTrue,
      );
      expect(
        UpdateRelease(revision, manifest('0.3.0')).newerThan('0.3.0-beta.10'),
        isTrue,
      );
      expect(UpdateRelease(revision, manifest()).newerThan('0.3.0'), isFalse);
      expect(
        UpdateRelease(revision, manifest()).newerThan('0.3.0-beta.2'),
        isFalse,
      );
    },
  );

  test('rejects malformed and redirected manifests', () {
    for (final invalid in [
      manifest().replaceFirst('Airreload/cli.git', 'someone/cli.git'),
      '${manifest()}CLI_TAG=v1.0.0\n',
      manifest().replaceFirst('CLI_COMMIT=$revision', 'CLI_COMMIT=bad'),
      manifest().replaceFirst('v0.3.0-beta.2', '../../bad'),
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
    'check displays why, changes, source and destination without mutations',
    () async {
      expect(await manager().update(checkOnly: true), 0);
      final output = logger.messages.join('\n');
      expect(output, contains('Installed: Airreload $cliVersion'));
      expect(output, contains('Available: Airreload 0.3.0-beta.2'));
      expect(output, contains('A newer CLI release'));
      expect(output, contains('/compare/v$cliVersion...v0.3.0-beta.2'));
      expect(output, contains(updateSource));
      expect(output, contains(root.path));
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

  test('equal and newer local versions never install', () async {
    for (final version in [cliVersion, '0.2.0']) {
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
  }, skip: Platform.isWindows);

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
    remoteManifest = manifest(cliVersion);
    await manager().notifyIfAvailable();
    expect(requests, hasLength(2));
    expect(logger.messages, isEmpty);
  });
}
