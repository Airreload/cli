import 'dart:io';
import 'dart:async';

import 'package:airreload/airreload.dart';
import 'package:airreload/src/run_workflow.dart';
import 'package:test/test.dart';
import 'package:test/fake.dart';

class Capture extends Fake implements Stdout {
  final text = StringBuffer();
  @override
  bool get supportsAnsiEscapes => false;
  @override
  bool get hasTerminal => false;
  @override
  void writeln([Object? object = '']) => text.writeln(object);
  @override
  void write(Object? object) => text.write(object);
}

class FakeOperations extends Operations {
  FakeOperations(super.workspace);
  final calls = <String>[];
  List<String>? arguments;
  RunOptions? runOptions;
  @override
  Future<int> runApp(RunOptions options) async {
    runOptions = options;
    calls.add("run");
    return 0;
  }

  Map<String, dynamic> data = {
    'port': 9443,
    'token': 'synthetic-test-pairing-token',
    'debugUrl': 'http://127.0.0.1:50001/test-auth=/',
  };
  @override
  Future<int> doctor() async {
    calls.add('doctor');
    return 0;
  }

  @override
  Future<void> host(int port) async {
    calls.add('host:$port');
  }

  @override
  Future<Map<String, dynamic>> session() async {
    calls.add('session');
    return data;
  }

  @override
  Future<int> attach(String project, List<String> arguments) async {
    calls.add('attach:$project');
    this.arguments = arguments;
    return 7;
  }
}

void main() {
  late Directory temporary;
  late FakeOperations operations;
  late Capture output;
  late Capture errors;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('airreload-test-');
    operations = FakeOperations(Workspace(temporary.path));
    output = Capture();
    errors = Capture();
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<int> run(List<String> args) => runZoned(
    () => IOOverrides.runZoned(
      () => runCli(args, operations),
      stdout: () => output,
      stderr: () => errors,
    ),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => output.writeln(line),
    ),
  );

  test(
    'help lists workflow and compatibility limits without generating state',
    () async {
      expect(await run([]), 0);
      for (final command in [
        'doctor',
        'host',
        'pair',
        'status',
        'attach',
        'version',
      ]) {
        expect(output.text.toString(), contains(command));
      }
      expect(output.text.toString(), contains('Pub workspaces'));
      expect(output.text.toString(), contains('hot restart'));
      expect(Directory(operations.workspace.state).existsSync(), isFalse);
      expect(operations.calls, isEmpty);
    },
  );
  test(
    'run keeps caller cwd and forwards target and build definitions',
    () async {
      expect(
        await run(['run', '-t', 'lib/custom.dart', '--dart-define', 'MODE=qa']),
        0,
      );
      expect(operations.runOptions!.project, Directory.current.path);
      expect(operations.runOptions!.target, 'lib/custom.dart');
      expect(operations.runOptions!.defines, ['MODE=qa']);
      expect(operations.calls, ['run']);
    },
  );

  test('run help mentions hot reload, hot restart, and DevTools', () async {
    expect(await run(['help', 'run']), 0);
    expect(output.text.toString(), contains('hot reload'));
    expect(output.text.toString(), contains('hot restart'));
    expect(output.text.toString(), contains('DevTools'));
  });

  test(
    'run forwards an exact Flutter override and rejects unavailable versions',
    () async {
      expect(await run(['run', '--flutter-version', '3.38.10']), 0);
      expect(operations.runOptions!.flutterVersion, '3.38.10');
      operations.calls.clear();
      expect(await run(['run', '--flutter-version', '3.38']), 64);
      expect(operations.calls, isEmpty);
    },
  );

  test('attach help mentions hot restart and DevTools', () async {
    expect(await run(['help', 'attach']), 0);
    expect(output.text.toString(), contains('hot restart'));
    expect(output.text.toString(), contains('DevTools'));
    expect(
      output.text.toString(),
      isNot(contains('does not support hot restart')),
    );
  });

  test('version flag is read-only', () async {
    expect(await run(['--version']), 0);
    expect(output.text.toString(), contains(cliVersion));
    expect(operations.calls, isEmpty);
  });
  test('doctor dispatches without starting host', () async {
    expect(await run(['doctor']), 0);
    expect(operations.calls, ['doctor']);
  });
  test('host validates port before any side effect', () async {
    for (final port in ['no', '0', '65536']) {
      expect(await run(['host', '--port', port]), 64);
    }
    expect(operations.calls, isEmpty);
    expect(Directory(operations.workspace.state).existsSync(), isFalse);
  });
  test('explicit host dispatches configured port', () async {
    expect(await run(['host', '--port', '9543']), 0);
    expect(operations.calls, ['host:9543']);
  });
  test(
    'status authenticates and never prints pairing token or VM auth path',
    () async {
      expect(await run(['status']), 0);
      expect(operations.calls, ['session']);
      expect(output.text.toString(), contains('App connected'));
      expect(
        output.text.toString(),
        isNot(contains('synthetic-test-pairing-token')),
      );
      expect(output.text.toString(), isNot(contains('test-auth')));
    },
  );
  test(
    'pair rejects missing or non-LAN address before reading session',
    () async {
      for (final args in [
        <String>[],
        ['--host', 'localhost'],
        ['--host', '127.0.0.1'],
      ]) {
        expect(await run(['pair', ...args]), 64);
      }
      expect(operations.calls, isEmpty);
    },
  );
  test(
    'pair explicitly shows session token and public certificate fingerprint',
    () async {
      await Directory(operations.workspace.state).create(recursive: true);
      await File(operations.workspace.certificate).writeAsString(
        '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----',
      );
      expect(await run(['pair', '--host', '192.0.2.10']), 0);
      expect(operations.calls, ['session']);
      expect(output.text.toString(), contains('synthetic-test-pairing-token'));
      expect(output.text.toString(), contains('Certificate SHA-256:'));
      expect(output.text.toString(), contains('another host identity'));
    },
  );
  test('attach rejects missing project before accessing host', () async {
    expect(await run(['attach', '--project', '${temporary.path}/missing']), 64);
    expect(operations.calls, isEmpty);
  });
  test('attach uses matching project, authenticated endpoint and propagates Flutter exit', () async {
    await File('${temporary.path}/pubspec.yaml').writeAsString('name: fixture');
    expect(
      await run([
        'attach',
        '--project',
        temporary.path,
        '--target',
        'lib/demo.dart',
      ]),
      7,
    );
    expect(operations.arguments, [
      'attach',
      '--airreload',
      '--debug-url=http://127.0.0.1:50001/test-auth=/',
      '--dds',
      '--devtools',
      '--target=lib/demo.dart',
    ]);
    expect(operations.calls, ['session', 'attach:${temporary.path}']);
  });
  test('attach refuses disconnected and invalid endpoints', () async {
    await File('${temporary.path}/pubspec.yaml').writeAsString('name: fixture');
    for (final url in [null, 'http://192.0.2.1:50001/token/']) {
      operations.data['debugUrl'] = url;
      expect(await run(['attach', '--project', temporary.path]), 1);
      expect(operations.arguments, isNull);
    }
  });
  test('unknown command and unexpected arguments fail', () async {
    expect(await run(['invalid']), 64);
    expect(await run(['status', 'extra']), 64);
    expect(operations.calls, isEmpty);
  });
  test('real entrypoint supports version and fails offline without creating credentials', () async {
    final script = File('bin/airreload.dart').absolute.path;
    final result = await Process.run(
      Platform.resolvedExecutable,
      [script, '--version'],
      environment: {'AIRRELOAD_WORKSPACE': temporary.path},
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains(cliVersion));
    final offline = await Process.run(
      Platform.resolvedExecutable,
      [script, 'status'],
      environment: {'AIRRELOAD_WORKSPACE': temporary.path},
    );
    expect(offline.exitCode, 1);
    expect(offline.stderr, contains('Host is not running'));
    expect(Directory(operations.workspace.state).existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
