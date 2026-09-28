// Runs a compiled CLI from an installer layout with no Flutter or Dart files.
import 'dart:io';

import 'package:airreload/src/workspace.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Usage: <compiled CLI>');
  final temporary = await Directory.systemTemp.createTemp('airreload-native-');
  final root = Directory(await temporary.resolveSymbolicLinks());
  try {
    final bin = await Directory(p.join(root.path, 'bin')).create();
    final binary = await File(args.single).copy(
      p.join(bin.path, Platform.isWindows ? 'airreload.exe' : 'airreload'),
    );
    await File(p.join(root.path, '.airreload-installer'))
        .writeAsString('airreload-installer-v1\n');
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['755', binary.path]);
      if (result.exitCode != 0) {
        throw StateError('Could not make CLI executable');
      }
    }
    final environment = Map<String, String>.of(Platform.environment)
      ..remove('AIRRELOAD_WORKSPACE')
      ..['AIRRELOAD_NO_UPDATE_CHECK'] = '1';
    final pathKey = environment.keys.firstWhere(
      (key) => key.toLowerCase() == 'path',
      orElse: () => 'PATH',
    );
    environment[pathKey] =
        '${bin.path}${Platform.isWindows ? ';' : ':'}${environment[pathKey] ?? ''}';
    for (final argument in ['version', '--help', 'doctor']) {
      final result = await Process.run(
        binary.path,
        [argument],
        workingDirectory: Directory.systemTemp.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) {
        throw StateError(
          '$argument failed: ${result.stdout}\n${result.stderr}',
        );
      }
      final output = result.stdout.toString();
      if (argument == 'version' && output.trim() != 'Airreload $cliVersion') {
        throw StateError('Unexpected binary version: $output');
      }
      if (argument == 'doctor' && !output.contains(p.join(root.path, 'sdks'))) {
        throw StateError(
          'Binary did not resolve its own installation: $output',
        );
      }
      stdout.write(output);
    }
    // Invoke through the shell just as users do. Process.run with an absolute
    // executable path does not exercise Dart's native Platform.script behavior.
    final project = await Directory(
      p.join(root.path, 'projects', 'example', 'test_app'),
    ).create(recursive: true);
    final fromPath = await Process.run(
      Platform.isWindows ? 'cmd.exe' : '/bin/sh',
      Platform.isWindows
          ? ['/d', '/c', 'airreload doctor']
          : ['-c', 'airreload doctor'],
      workingDirectory: project.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    if (fromPath.exitCode != 0 ||
        !fromPath.stdout.toString().contains(p.join(root.path, 'sdks'))) {
      throw StateError(
        'PATH invocation used the wrong installation: '
        '${fromPath.stdout}\n${fromPath.stderr}',
      );
    }
    await Directory(p.join(root.path, 'projects')).delete(recursive: true);
    final entries = await root
        .list()
        .map((entry) => p.basename(entry.path))
        .toList();
    if (entries.length != 2 ||
        !entries.contains('bin') ||
        !entries.contains('.airreload-installer')) {
      throw StateError('Read-only commands created files: $entries');
    }
    stdout.writeln(
      'Native CLI works without a bundled SDK or source checkout.',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
