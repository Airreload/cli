import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      (Platform.isMacOS && Platform.environment['HOME'] != null
          ? p.join(Platform.environment['HOME']!, 'Library', 'Android', 'sdk')
          : '');
  final platforms = Directory(p.join(sdk, 'platforms'));
  final jars = platforms.existsSync()
      ? platforms
            .listSync()
            .whereType<Directory>()
            .map((dir) => File(p.join(dir.path, 'android.jar')))
            .where((file) => file.existsSync())
            .toList()
      : <File>[];
  test(
    'native process startup discards old VM endpoints and preserves other files',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'airreload-native-test-',
      );
      try {
        final javaHome = Platform.environment['JAVA_HOME'];
        String tool(String name) =>
            javaHome == null ? name : p.join(javaHome, 'bin', name);
        final compile = await Process.run(tool('javac'), [
          '--release',
          '8',
          '-cp',
          jars.first.path,
          '-d',
          temporary.path,
          'lib/src/android/AirreloadNativeTunnel.java',
          'test/native/AirreloadVmCacheTest.java',
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}\n${compile.stderr}',
        );
        final run = await Process.run(tool('java'), [
          '-cp',
          '${temporary.path}${Platform.isWindows ? ';' : ':'}${jars.first.path}',
          'dev.airreload.runtime.AirreloadVmCacheTest',
          temporary.path,
        ]);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        expect(run.stdout, contains('Native VM cache regression passed'));
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: jars.isEmpty
        ? 'An Android SDK platform and JDK are required for the native runtime check.'
        : false,
  );
}
