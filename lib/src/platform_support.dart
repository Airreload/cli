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
  final scriptFile = File.fromUri(script).absolute;
  final installedRoot = scriptFile.parent.parent;
  if (p.basename(scriptFile.parent.path).toLowerCase() == 'bin' &&
      File(p.join(installedRoot.path, '.airreload-installer')).existsSync()) {
    return installedRoot.path;
  }
  var directory = scriptFile.parent;
  while (directory.parent.path != directory.path) {
    if (p.basename(directory.path).toLowerCase() == 'cli') {
      return directory.parent.path;
    }
    directory = directory.parent;
  }
  return scriptFile.parent.parent.parent.path;
}

String flutterLauncher(String root, {bool? windows}) => p.join(
  root,
  'flutter',
  'bin',
  (windows ?? Platform.isWindows) ? 'flutter.bat' : 'flutter',
);

Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  ProcessStartMode mode = ProcessStartMode.normal,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  mode: mode,
);

Future<ProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(executable, arguments, workingDirectory: workingDirectory);

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
