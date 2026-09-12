import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

bool get isSupportedHost =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

String workspaceRootFromScript(Uri script, {Map<String, String>? environment}) {
  final configured =
      (environment ?? Platform.environment)['AIRRELOAD_WORKSPACE'];
  if (configured != null && configured.isNotEmpty) {
    return p.normalize(p.absolute(configured));
  }
  var directory = File.fromUri(script).absolute.parent;
  while (directory.parent.path != directory.path) {
    if (p.basename(directory.path).toLowerCase() == 'cli') {
      return directory.parent.path;
    }
    directory = directory.parent;
  }
  return File.fromUri(script).absolute.parent.parent.parent.path;
}

String flutterLauncher(String root, {bool? windows}) => p.join(
  root,
  'flutter',
  'bin',
  (windows ?? Platform.isWindows) ? 'flutter.bat' : 'flutter',
);

bool _needsShell(String executable) {
  if (!Platform.isWindows) return false;
  final extension = p.extension(executable).toLowerCase();
  return extension == '.bat' || extension == '.cmd';
}

String _processExecutable(String executable) {
  if (Platform.isWindows &&
      executable.contains(' ') &&
      !executable.contains('"')) {
    return '"$executable"';
  }
  return executable;
}

Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  ProcessStartMode mode = ProcessStartMode.normal,
}) => Process.start(
  _processExecutable(executable),
  arguments,
  workingDirectory: workingDirectory,
  runInShell: _needsShell(executable),
  mode: mode,
);

Future<ProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(
  _processExecutable(executable),
  arguments,
  workingDirectory: workingDirectory,
  runInShell: _needsShell(executable),
);

List<StreamSubscription<ProcessSignal>> watchTermination(
  void Function() terminate,
) {
  final signals = <ProcessSignal>[
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  return [
    for (final signal in signals) signal.watch().listen((_) => terminate()),
  ];
}

void stopProcess(Process process) {
  if (Platform.isWindows) {
    process.kill();
  } else {
    process.kill(ProcessSignal.sigint);
  }
}

Future<void> restrictAccess(String path, {required bool directory}) async {
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', [
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not restrict access to $path.');
    }
    return;
  }

  final identity = await Process.run('whoami.exe', [
    '/user',
    '/fo',
    'csv',
    '/nh',
  ]);
  final sid = RegExp(r'S-\d-(?:\d+-)+\d+')
      .firstMatch(identity.stdout.toString());
  if (identity.exitCode != 0 || sid == null) {
    throw StateError('Could not identify the current Windows user.');
  }
  final permission = directory ? '(OI)(CI)F' : 'F';
  final result = await Process.run('icacls.exe', [
    path,
    '/inheritance:r',
    '/grant:r',
    '*${sid.group(0)}:$permission',
    '/grant:r',
    '*S-1-5-18:$permission',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not restrict access to $path.');
  }
}

Future<void> createDirectoryLink(String link, String target) async {
  if (!Platform.isWindows) {
    await Link(link).create(target);
    return;
  }
  final result = await Process.run('cmd.exe', [
    '/d',
    '/c',
    'mklink',
    '/j',
    link,
    target,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not link the live Dart sources into the temporary build: '
      '${result.stderr.toString().trim()}',
    );
  }
}
