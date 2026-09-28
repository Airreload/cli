import 'dart:io';

import 'package:airreload/src/cli.dart';
import 'package:airreload/src/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('doctor succeeds without a Flutter SDK and creates no state', () async {
    final root = await Directory.systemTemp.createTemp('airreload-doctor-');
    try {
      expect(await Operations(Workspace(root.path)).doctor(), 0);
      expect(await root.list().isEmpty, isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
