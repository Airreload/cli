import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/android_runtime.dart';
import 'package:airreload/src/runtime_template.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('debug manifest merge adds INTERNET and the native tunnel provider', () {
    const empty =
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"></manifest>';
    final merged = mergeAirreloadDebugManifest(empty);
    expect(merged, contains('android.permission.INTERNET'));
    expect(merged, contains('dev.airreload.runtime.AirreloadInitProvider'));
    expect(merged, contains(r'${applicationId}.airreload.init'));
    expect(merged, contains('<application>'));
    expect(
      mergeAirreloadDebugManifest(merged),
      contains('AirreloadInitProvider'),
    );
    expect(
      mergeAirreloadDebugManifest('<manifest></manifest>')
          .contains('xmlns:android'),
      isTrue,
    );
  });

  test(
    'session asset stays JSON with host, port, token and certificate pin',
    () {
      final encoded = jsonDecode(
        airreloadSessionAsset(
          host: '192.0.2.3',
          port: 12345,
          token: 'synthetic-session',
          certificatePin: 'AQID',
        ),
      );
      expect(encoded, {
        'host': '192.0.2.3',
        'port': 12345,
        'token': 'synthetic-session',
        'certificatePin': 'AQID',
      });
    },
  );

  test(
    'generated Dart runtime publishes the VM URI and never opens WSS itself',
    () {
      expect(runtimeTemplate, contains('airreload-vm.json'));
      expect(runtimeTemplate, contains('controlWebServer'));
      expect(runtimeTemplate, isNot(contains('WebSocket.connect')));
      expect(runtimeTemplate, isNot(contains("import 'tunnel.dart'")));
      expect(runtimeTemplate, isNot(contains("import 'config.dart'")));
    },
  );

  test('Android native runtime sources exist beside the CLI', () {
    final source = androidRuntimeSourceDirectory(Directory.current.parent.path);
    for (final name in androidRuntimeJavaFiles) {
      final file = File(p.join(source, name));
      expect(file.existsSync(), isTrue, reason: file.path);
    }
    expect(
      File(p.join(source, 'AirreloadNativeTunnel.java')).readAsStringSync(),
      contains('FlutterJNI'),
    );
    expect(
      File(p.join(source, 'AirreloadInitProvider.java')).readAsStringSync(),
      contains('AirreloadNativeTunnel.start'),
    );
  });
}
