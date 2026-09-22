import 'dart:io';

import 'package:airreload/src/flutter_sdk.dart';
import 'package:mason_logger/mason_logger.dart';

// Exercises the same installer used by `airreload run`, without starting pairing.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: <Airreload workspace> <exact Flutter version>');
  }
  final manager = FlutterSdkManager(Directory(args[0]).absolute.path, Logger());
  final sdk = await manager.install(exactFlutterRelease(args[1]));
  stdout.writeln(sdk);
}
