// Builds an instrumented fixture without pairing; phone acceptance is separate.
import 'dart:io';

import 'package:airreload/src/instrumentation.dart';
import 'package:airreload/src/workspace.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('Usage: <SDK path> <workspace> <output>');
  }
  final sdk = Workspace(p.absolute(args[1]), sdkRoot: p.absolute(args[0]));
  final output = p.absolute(args[2]);
  final source = p.join(output, 'app');
  Future<void> flutter(List<String> command, {String? cwd}) async {
    final child = await Process.start(
      sdk.flutter,
      command,
      workingDirectory: cwd,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await child.exitCode;
    if (code != 0) throw StateError('Flutter ${command.first} failed: $code');
  }

  await Directory(output).create(recursive: true);
  await flutter([
    'create',
    '--platforms=android',
    '--empty',
    '--project-name=airreload_fixture',
    source,
  ]);
  final prepared = await PreparedProject.create(
    source: source,
    destination: p.join(output, 'prepared'),
    target: 'lib/main.dart',
    sdk: sdk,
    host: '192.0.2.1',
    port: 9443,
    token: 'synthetic-build-check',
    certificate: '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----',
  );
  await flutter([
    'build',
    'apk',
    '--debug',
    '--target-platform=android-arm64',
    '--android-skip-build-dependency-validation',
    '--target=${prepared.target}',
  ], cwd: prepared.directory);
  stdout.writeln('AIRRELOAD_ANDROID_BUILD_PASSED');
}
