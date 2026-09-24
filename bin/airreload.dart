import 'dart:io';

import 'package:airreload/airreload.dart';
import 'package:airreload/src/platform_support.dart';
import 'package:airreload/src/update.dart';

Future<void> main(List<String> args) async {
  final root = workspaceRootFromScript(Platform.script);
  final workspace = Workspace(root);
  if (Platform.environment['AIRRELOAD_NO_UPDATE_CHECK'] != '1' &&
      stdout.hasTerminal &&
      args.isNotEmpty &&
      {'run', 'doctor'}.contains(args.first) &&
      !args.contains('--help') &&
      !args.contains('-h')) {
    await UpdateManager(workspace).notifyIfAvailable();
  }
  exitCode = await runCli(args, Operations(workspace));
}
