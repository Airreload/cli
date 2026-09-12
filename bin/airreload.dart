import 'dart:io';

import 'package:airreload/airreload.dart';

Future<void> main(List<String> args) async {
  final root =
      Platform.environment['AIRRELOAD_WORKSPACE'] ??
      File.fromUri(Platform.script).parent.parent.parent.path;
  exitCode = await runCli(args, Operations(Workspace(root)));
}
