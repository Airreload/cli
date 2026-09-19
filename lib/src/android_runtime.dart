import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const androidRuntimeJavaFiles = [
  'AirreloadInitProvider.java',
  'AirreloadNativeTunnel.java',
];

const androidRuntimeJavaPackagePath = 'dev/airreload/runtime';

const airreloadVmEndpointFileName = 'airreload-vm.json';

String androidRuntimeSourceDirectory(String workspaceRoot) =>
    p.join(workspaceRoot, 'cli', 'lib', 'src', 'android');

String airreloadSessionAsset({
  required String host,
  required int port,
  required String token,
  required String certificatePin,
}) => jsonEncode({
  'host': host,
  'port': port,
  'token': token,
  'certificatePin': certificatePin,
});

String mergeAirreloadDebugManifest(String text) {
  if (!text.contains('xmlns:android')) {
    text = text.replaceFirst(
      '<manifest',
      '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
    );
  }
  if (!text.contains('android.permission.INTERNET')) {
    text = text.replaceFirst(
      '</manifest>',
      '<uses-permission android:name="android.permission.INTERNET"/></manifest>',
    );
  }
  if (!text.contains('dev.airreload.runtime.AirreloadInitProvider')) {
    const provider =
        '<provider android:name="dev.airreload.runtime.AirreloadInitProvider" '
        r'android:authorities="${applicationId}.airreload.init" '
        'android:exported="false" android:initOrder="2147483647"/>';
    if (text.contains('</application>')) {
      text = text.replaceFirst('</application>', '$provider</application>');
    } else {
      text = text.replaceFirst(
        '</manifest>',
        '<application>$provider</application></manifest>',
      );
    }
  }
  return text;
}

Future<void> injectAirreloadAndroidRuntime({
  required String destination,
  required String workspaceRoot,
  required String host,
  required int port,
  required String token,
  required String certificatePin,
}) async {
  final source = Directory(androidRuntimeSourceDirectory(workspaceRoot));
  final java = Directory(
    p.join(
      destination,
      'android',
      'app',
      'src',
      'debug',
      'java',
      androidRuntimeJavaPackagePath,
    ),
  );
  await java.create(recursive: true);
  for (final name in androidRuntimeJavaFiles) {
    final file = File(p.join(source.path, name));
    if (!await file.exists()) {
      throw StateError('Missing Airreload Android runtime file: ${file.path}');
    }
    await file.copy(p.join(java.path, name));
  }
  final assets = Directory(
    p.join(destination, 'android', 'app', 'src', 'debug', 'assets'),
  );
  await assets.create(recursive: true);
  await File(p.join(assets.path, 'airreload-session.json')).writeAsString(
    airreloadSessionAsset(
      host: host,
      port: port,
      token: token,
      certificatePin: certificatePin,
    ),
  );
  final manifest = File(
    p.join(
      destination,
      'android',
      'app',
      'src',
      'debug',
      'AndroidManifest.xml',
    ),
  );
  await manifest.parent.create(recursive: true);
  final original = await manifest.exists()
      ? await manifest.readAsString()
      : '<manifest xmlns:android="http://schemas.android.com/apk/res/android"></manifest>';
  await manifest.writeAsString(mergeAirreloadDebugManifest(original));
}
