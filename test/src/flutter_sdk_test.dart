import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/flutter_sdk.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String project;
  final logger = Logger(level: Level.quiet);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('airreload-sdk-test-');
    project = p.join(temp.path, 'project');
    await Directory(project).create();
    await File(p.join(project, 'pubspec.yaml'))
        .writeAsString('name: fixture\n');
  });
  tearDown(() => temp.delete(recursive: true));

  test('version metadata accepts first-run download output before JSON', () {
    expect(
      flutterVersionMetadata(
        '  % Total    % Received\r100 215M\nBuilding flutter tool...\n{\n"frameworkVersion":"3.47.5"\n}\n',
      ),
      containsPair('frameworkVersion', '3.47.5'),
    );
    expect(
      () => flutterVersionMetadata('download failed'),
      throwsFormatException,
    );
  });

  Future<ProcessResult> forbidden(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async => throw StateError('Unexpected subprocess');

  test(
    'explicit exact selection ignores malformed FVM and never probes Flutter',
    () async {
      await File(p.join(project, '.fvmrc')).writeAsString('{broken');
      final manager = FlutterSdkManager(temp.path, logger, command: forbidden);
      for (final release in flutterReleases) {
        expect(
          await manager.select(project, requested: release.version),
          same(release),
        );
      }
    },
  );

  test(
    'unsupported or partial explicit version never falls back to FVM',
    () async {
      await File(p.join(project, '.fvmrc'))
          .writeAsString('{"flutter":"3.47.5"}');
      final manager = FlutterSdkManager(temp.path, logger, command: forbidden);
      for (final version in ['3.47', 'stable', '3.47.2', '../3.47.5']) {
        await expectLater(
          manager.select(project, requested: version),
          throwsStateError,
        );
      }
    },
  );

  test(
    'FVM wins over PATH and supports nearest parent and legacy config',
    () async {
      final file = File(p.join(project, '.fvmrc'));
      await file.writeAsString('{"flutter":"3.44.9"}');
      final nested = await Directory(p.join(project, 'nested')).create();
      final manager = FlutterSdkManager(temp.path, logger, command: forbidden);
      expect((await manager.select(nested.path)).version, '3.44.9');
      await file.delete();
      final legacy = File(p.join(project, '.fvm', 'fvm_config.json'));
      await legacy.parent.create();
      await legacy.writeAsString('{"flutterSdkVersion":"3.38.10"}');
      expect((await manager.select(project)).version, '3.38.10');
      await file.writeAsString('{"flutter":"3.41.9"}');
      expect((await manager.select(project)).version, '3.41.9');
    },
  );

  test(
    'malformed FVM is reported instead of using an unrelated installed SDK',
    () async {
      await File(p.join(project, '.fvmrc')).writeAsString('{"flutter":42}');
      await expectLater(
        FlutterSdkManager(
          temp.path,
          logger,
          command: forbidden,
        ).select(project),
        throwsStateError,
      );
    },
  );

  test('PATH detection is used without FVM', () async {
    final manager = FlutterSdkManager(
      temp.path,
      logger,
      command: (executable, args, {workingDirectory}) async {
        expect(args, ['--version', '--machine']);
        expect(workingDirectory, project);
        return ProcessResult(1, 0, '{"frameworkVersion":"3.41.9"}', '');
      },
    );
    expect((await manager.select(project)).version, '3.41.9');
  });

  test(
    'matching bundled runtime is verified and reused without downloading',
    () async {
      final fake = FakeSdkCommands();
      final sdk = p.join(temp.path, 'flutter');
      final version = File(p.join(sdk, 'bin', 'internal', 'airreload.version'));
      await version.parent.create(recursive: true);
      await version.writeAsString(fake.release.version);
      final dart = File(
        p.join(
          sdk,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      await dart.parent.create(recursive: true);
      await dart.writeAsString('fixture');
      final manager = FlutterSdkManager(temp.path, logger, command: fake.run);
      expect(await manager.install(fake.release), sdk);
      expect(fake.clones, 0);
      fake.wrongCommit = true;
      await expectLater(manager.install(fake.release), throwsStateError);
    },
  );

  test('SDK cache verifies exact identity, reuses a ready install, and rejects edits', () async {
    final fake = FakeSdkCommands();
    final manager = FlutterSdkManager(temp.path, logger, command: fake.run);
    final directory = await manager.install(fake.release);
    expect(fake.clones, 1);
    expect(
      await File(p.join(directory, '.airreload-ready')).readAsString(),
      fake.release.commit,
    );
    expect(await manager.install(fake.release), directory);
    expect(fake.clones, 1);
    fake.dirty = true;
    await expectLater(manager.install(fake.release), throwsStateError);
  });

  test(
    'wrong downloaded commit is never bootstrapped or marked ready',
    () async {
      final fake = FakeSdkCommands()..wrongCommit = true;
      final manager = FlutterSdkManager(temp.path, logger, command: fake.run);
      await expectLater(manager.install(fake.release), throwsStateError);
      expect(fake.bootstraps, 0);
      expect(
        await Directory(manager.cache)
            .list()
            .where((e) => e is Directory)
            .isEmpty,
        isTrue,
      );
    },
  );

  test('failed bootstrap is cleaned up and can be retried', () async {
    final fake = FakeSdkCommands()..failBootstrap = true;
    final manager = FlutterSdkManager(temp.path, logger, command: fake.run);
    await expectLater(manager.install(fake.release), throwsStateError);
    fake.failBootstrap = false;
    final directory = await manager.install(fake.release);
    expect(fake.clones, 2);
    expect(await File(p.join(directory, '.airreload-ready')).exists(), isTrue);
  });
}

class FakeSdkCommands {
  final release = FlutterRelease(
    '3.47.5',
    '3.13.4',
    List.filled(40, 'a').join(),
  );
  var clones = 0;
  var bootstraps = 0;
  var dirty = false;
  var wrongCommit = false;
  var failBootstrap = false;

  Future<ProcessResult> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    Object output = '';
    var code = 0;
    if (args.first == 'clone') {
      clones++;
      final dart = File(
        p.join(
          args.last,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      await dart.parent.create(recursive: true);
      await dart.writeAsString('fixture');
    } else if (args.contains('rev-parse')) {
      output = wrongCommit ? 'wrong' : release.commit;
    } else if (args.contains('status')) {
      output = dirty
          ? ' M packages/flutter_tools/lib/src/commands/attach.dart'
          : '';
    } else if (args.first == '--version') {
      bootstraps++;
      code = failBootstrap ? 1 : 0;
      output =
          'Downloading SDK...\n${jsonEncode({'frameworkRevision': release.commit, 'frameworkVersion': release.version})}';
    } else if (args.first == 'attach') {
      output = '--airreload --airreload-target-platform';
    } else if (!args.contains('fetch')) {
      throw StateError('Unexpected command $executable $args');
    }
    return ProcessResult(1, code, output, code == 0 ? '' : 'fixture failure');
  }
}
