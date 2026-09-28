// Record the checksum of the exact executable uploaded by release CI.
import 'dart:io';

import 'package:airreload/src/workspace.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Usage: <compiled CLI>');
  if (Platform.environment['GITHUB_REF_TYPE'] == 'tag' &&
      Platform.environment['GITHUB_REF_NAME'] != 'v$cliVersion') {
    throw StateError('Release tag must match CLI version v$cliVersion.');
  }
  final binary = File(args.single);
  final digest = await sha256.bind(binary.openRead()).first;
  final line = '$digest  ${p.basename(binary.path)}\n';
  await File('${binary.path}.sha256').writeAsString(line);
  stdout.write(line);
}
