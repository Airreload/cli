import 'dart:io';

import 'package:airreload/airreload.dart';
import 'package:airreload/src/platform_support.dart';

Future<void> main(List<String> args) async {
  final root = workspaceRootFromScript(Platform.script);
  exitCode = await runCli(args, Operations(Workspace(root)));
}
