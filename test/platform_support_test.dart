import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/platform_support.dart';
import 'package:airreload/src/run_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('workspace root is found from nested build and bin locations', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'airreload-root-test-',
    );
    try {
      final cli = Directory(p.join(temporary.path, 'cli'));
      final binScript = File(p.join(cli.path, 'bin', 'airreload.dart'));
      final nestedBinary = File(
        p.join(cli.path, 'build', 'verification', 'airreload'),
      );
      expect(
        workspaceRootFromScript(binScript.absolute.uri, environment: const {}),
        temporary.path,
      );
      expect(
        workspaceRootFromScript(
          nestedBinary.absolute.uri,
          environment: const {},
        ),
        temporary.path,
      );
      expect(
        workspaceRootFromScript(
          binScript.absolute.uri,
          environment: {'AIRRELOAD_WORKSPACE': cli.path},
        ),
        cli.path,
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('Flutter launcher uses the native platform filename', () {
    expect(p.basename(flutterLauncher('root', windows: false)), 'flutter');
    expect(p.basename(flutterLauncher('root', windows: true)), 'flutter.bat');
  });

  test(
    'physical Windows and Unix interface names outrank virtual adapters',
    () {
      expect(isVirtualInterface('vEthernet (Default Switch)'), isTrue);
      expect(isVirtualInterface('DockerNAT'), isTrue);
      expect(isVirtualInterface('Wi-Fi'), isFalse);
      expect(isVirtualInterface('Ethernet'), isFalse);
      expect(
        networkAddressRank('Wi-Fi', '192.168.1.5'),
        lessThan(networkAddressRank('vEthernet', '172.20.0.1')),
      );
      expect(
        networkAddressRank('Ethernet', '10.0.0.2', preferred: 'Ethernet'),
        0,
      );
    },
  );

  test(
    'Windows batch launch preserves arguments and paths containing spaces',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'airreload batch test ',
      );
      try {
        final batch = File(p.join(temporary.path, 'echo arguments.bat'));
        await batch.writeAsString('@echo off\r\necho %~1\r\n');
        final process = await startProcess(batch.path, ['value with spaces']);
        final output = await utf8.decoder.bind(process.stdout).join();
        final errors = await utf8.decoder.bind(process.stderr).join();
        expect(await process.exitCode, 0, reason: errors);
        expect(output.trim(), 'value with spaces');
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
