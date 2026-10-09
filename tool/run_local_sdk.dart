import 'dart:io';

import 'package:airreload/airreload.dart';
import 'package:airreload/src/run_workflow.dart';
import 'package:path/path.dart' as p;

// Development launcher: preserve the normal pairing/build flow while using
// this checkout's modified Flutter SDK instead of immutable release SDKs.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first != 'run') {
    stderr.writeln('Usage: airreload-dev run --project /path/to/flutter-app');
    exitCode = 64;
    return;
  }
  final root = p.dirname(p.dirname(p.dirname(Platform.script.toFilePath())));
  exitCode = await runCli(args, _LocalOperations(Workspace(root)));
}

class _LocalOperations extends Operations {
  _LocalOperations(super.workspace);

  @override
  Future<int> runApp(RunOptions options) => RunWorkflow(
    workspace,
    logger: logger,
    developmentSdk: workspace,
  ).run(options);
}
