import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/instrumentation.dart';
import 'package:airreload/src/session_host.dart';
import 'package:airreload/src/workspace.dart';
import 'package:airreload/src/run_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('successful Flutter exit means finish only while the same app connection remains', () {
    expect(
      shouldFinishAttach(0, stillConnected: true, sameConnection: true),
      isTrue,
    );
    expect(
      shouldFinishAttach(0, stillConnected: false, sameConnection: true),
      isFalse,
    );
    expect(
      shouldFinishAttach(0, stillConnected: true, sameConnection: false),
      isFalse,
    );
    expect(
      shouldFinishAttach(1, stillConnected: true, sameConnection: true),
      isFalse,
    );
  });

  test(
    'lost connections and failed attach exits explain the reconnect wait',
    () {
      expect(
        attachEndedMessage(0, stillConnected: false, sameConnection: true),
        contains('Lost the app connection'),
      );
      expect(
        attachEndedMessage(1, stillConnected: true, sameConnection: false),
        contains('reconnect'),
      );
      expect(
        attachEndedMessage(1, stillConnected: true, sameConnection: true),
        contains('exit 1'),
      );
    },
  );

  test('wrapper preserves async and argument-taking main without installing a binding or UI', () {
    final wrapper = entrypointWrapper(
      'package:example/main.dart',
      'Future<void> main(List<String> args) async {}',
    );
    expect(wrapper, contains('app.main(const <String>[])'));
    expect(wrapper, contains('Future<void>.sync'));
    expect(wrapper, isNot(contains('runApp')));
    expect(wrapper, isNot(contains('ensureInitialized')));
    expect(
      entrypointWrapper('package:example/other.dart', 'void main() {}'),
      contains('app.main()'),
    );
    expect(
      () => entrypointWrapper('x.dart', 'void other() {}'),
      throwsStateError,
    );
    expect(
      () => entrypointWrapper('x.dart', 'void main({String? x}) {}'),
      throwsStateError,
    );
    expect(dartLiteral(r'a$b'), '"a\\\$b"');
  });

  test('instrumentation preserves app files and release manifest; live lib and path dependencies stay consistent', () async {
    final temp = await Directory.systemTemp.createTemp('airreload-instrument-');
    try {
      final source = Directory(p.join(temp.path, 'app'));
      await Directory(p.join(source.path, 'lib')).create(recursive: true);
      final main = File(p.join(source.path, 'lib', 'main.dart'));
      await main.writeAsString('void main() {}');
      final spec = File(p.join(source.path, 'pubspec.yaml'));
      const yaml =
          'name: fixture\ndependencies:\n  shared:\n    path: ../shared\n';
      await spec.writeAsString(yaml);
      final manifest = File(
        p.join(
          source.path,
          'android',
          'app',
          'src',
          'main',
          'AndroidManifest.xml',
        ),
      );
      await manifest.parent.create(recursive: true);
      await manifest.writeAsString(
        '<manifest><application android:label="User App"/></manifest>',
      );
      final localProperties = File(
        p.join(source.path, 'android', 'local.properties'),
      );
      await localProperties.writeAsString(
        'sdk.dir=/android-sdk\nflutter.sdk=/old/flutter\n',
      );
      final oldSdk = File(
        p.join(source.path, '.fvm', 'flutter_sdk', 'large-cache'),
      );
      await oldSdk.parent.create(recursive: true);
      await oldSdk.writeAsString('must not copy');
      final prepared = await PreparedProject.create(
        source: source.path,
        destination: p.join(temp.path, 'shadow'),
        target: 'lib/main.dart',
        sdk: Workspace(Directory.current.parent.path),
        host: '192.0.2.3',
        port: 12345,
        token: 'synthetic-session',
        certificate:
            '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----',
      );
      expect(await spec.readAsString(), yaml);
      expect(
        await Directory(p.join(prepared.directory, '.fvm')).exists(),
        isFalse,
      );
      expect(
        await localProperties.readAsString(),
        contains('flutter.sdk=/old/flutter'),
      );
      expect(
        await File(p.join(prepared.directory, 'android', 'local.properties'))
            .readAsString(),
        allOf(
          contains('sdk.dir=/android-sdk'),
          isNot(contains('/old/flutter')),
        ),
      );
      expect(await main.readAsString(), 'void main() {}');
      expect(
        await File(
          p.join(
            prepared.directory,
            'android',
            'app',
            'src',
            'main',
            'AndroidManifest.xml',
          ),
        ).readAsString(),
        await manifest.readAsString(),
      );
      expect(
        await File(
          p.join(
            source.path,
            'android',
            'app',
            'src',
            'debug',
            'AndroidManifest.xml',
          ),
        ).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(
            prepared.directory,
            'android',
            'app',
            'src',
            'debug',
            'AndroidManifest.xml',
          ),
        ).readAsString(),
        allOf(
          contains('android.permission.INTERNET'),
          contains('dev.airreload.runtime.AirreloadInitProvider'),
        ),
      );
      expect(
        await File(
          p.join(
            prepared.directory,
            'android',
            'app',
            'src',
            'debug',
            'java',
            'dev',
            'airreload',
            'runtime',
            'AirreloadNativeTunnel.java',
          ),
        ).exists(),
        isTrue,
      );
      expect(
        jsonDecode(
          await File(
            p.join(
              prepared.directory,
              'android',
              'app',
              'src',
              'debug',
              'assets',
              'airreload-session.json',
            ),
          ).readAsString(),
        ),
        containsPair('host', '192.0.2.3'),
      );
      expect(
        await File(p.join(p.dirname(prepared.target), 'runtime.dart'))
            .readAsString(),
        allOf(
          contains('airreload-vm.json'),
          isNot(contains('WebSocket.connect')),
        ),
      );
      expect(
        await File(p.join(p.dirname(prepared.target), 'tunnel.dart')).exists(),
        isFalse,
      );
      final document = loadYaml(
        await File(p.join(prepared.directory, 'pubspec.yaml')).readAsString(),
      ) as YamlMap;
      expect(
        (document['dependencies'] as YamlMap)['shared']['path'],
        p.join(temp.path, 'shared'),
      );
      await main.writeAsString('void main() { print("changed"); }');
      expect(
        await File(p.join(prepared.directory, 'lib', 'main.dart'))
            .readAsString(),
        contains('changed'),
      );
      final config = await File(
        p.join(p.dirname(prepared.target), 'config.dart'),
      ).readAsString();
      expect(config, contains('12345'));
      expect(config, contains('synthetic-session'));
      expect(config, contains('AQID'));
      final arguments = RunOptions(
        project: source.path,
        defines: ['MODE=qa'],
        defineFiles: ['env.json'],
      ).dartArguments;
      expect(arguments, [
        '--dart-define=MODE=qa',
        '--dart-define-from-file=${p.join(source.path, 'env.json')}',
      ]);
      expect(
        attachArguments('http://127.0.0.1:50001/token=/', 'lib/main.dart'),
        [
          'attach',
          '--airreload',
          '--debug-url=http://127.0.0.1:50001/token=/',
          '--dds',
          '--devtools',
          '--target=lib/main.dart',
        ],
      );
      expect(
        attachArguments(
          'http://127.0.0.1:50001/token=/',
          'lib/main.dart',
          targetPlatform: 'android-x64',
        ),
        contains('--airreload-target-platform=android-x64'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test(
    'APK download serves only the exact artifact and stops on close',
    () async {
      final temp = await Directory.systemTemp.createTemp('airreload-apk-test-');
      final apk = File(p.join(temp.path, 'fixture.apk'));
      await apk.writeAsBytes([0, 255, 128, 42]);
      final server = await ApkServer.start(apk);
      final client = HttpClient();
      final url = server.url('127.0.0.1');
      try {
        final response = await (await client.getUrl(url)).close();
        expect(response.statusCode, 200);
        expect(
          await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          ),
          [0, 255, 128, 42],
        );
        expect(
          response.headers.value('content-disposition'),
          contains('attachment'),
        );
        for (final path in ['/', '/pubspec.yaml', '${server.route}/extra']) {
          final response = await (await client.getUrl(url.replace(path: path)))
              .close();
          expect(response.statusCode, 404);
          await response.drain<void>();
        }
        final head = await (await client.openUrl('HEAD', url)).close();
        expect(head.contentLength, 4);
        expect(await head.length, 0);
        await server.close();
        client.close(force: true);
        final closedClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        await expectLater(
          closedClient.getUrl(url),
          throwsA(isA<SocketException>()),
        );
        closedClient.close(force: true);
      } finally {
        client.close(force: true);
        await server.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('session TLS host authenticates, reports an app, and allows reconnect after disconnect', () async {
    final temp = await Directory.systemTemp.createTemp(
      'airreload-session-test-',
    );
    final workspace = SessionWorkspace(
      Directory.current.parent.path,
      temp.path,
    );
    final server = await SessionHost.start(workspace);
    final pin = base64Encode(
      certificateDer(await File(workspace.certificate).readAsString()),
    );
    HttpClient client() =>
        HttpClient(context: SecurityContext(withTrustedRoots: false))
          ..badCertificateCallback = (cert, host, port) =>
              base64Encode(cert.der) == pin;
    final http = client();
    final uri = Uri(
      scheme: 'wss',
      host: '127.0.0.1',
      port: server.server.port,
      path: '/connect',
    );
    try {
      final request = await http.getUrl(uri.replace(scheme: 'https'));
      request.headers.set('Authorization', 'Bearer deliberately-wrong');
      final response = await request.close();
      expect(response.statusCode, 401);
      await response.drain<void>();
      for (final authPath in ['/first-token=/', '/second-token=/']) {
        final ready = server.waitForApp();
        final link = await WebSocket.connect(
          uri.toString(),
          customClient: http,
          headers: {
            'Authorization': 'Bearer ${server.token}',
            'x-airreload-vm-path': authPath,
          },
        );
        expect((await ready).path, authPath);
        await link.close();
        for (var i = 0; i < 30 && server.debugUri != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(server.debugUri, isNull);
      }
    } finally {
      http.close(force: true);
      await server.close();
      await temp.delete(recursive: true);
    }
  });

  test('terminal QR has explicit contrast and four-module quiet zone', () {
    final qr = terminalQr('http://192.0.2.1:1234/synthetic/app-debug.apk');
    expect(qr, startsWith('\x1b[30;47m    '));
    expect(qr, contains('▀'));
    expect(qr, contains('\x1b[0m'));
  });

  test(
    'Flutter Android target selection follows the documented ABI preference',
    () {
      expect(
        flutterAndroidTargetForAbis(['arm64-v8a', 'armeabi-v7a']),
        'android-arm64',
      );
      expect(
        flutterAndroidTargetForAbis(['armeabi-v7a', 'x86_64']),
        'android-arm',
      );
      expect(flutterAndroidTargetForAbis(['x86_64']), 'android-x64');
      expect(flutterAndroidTargetForAbis(['x86']), isNull);
    },
  );

  test('pairing endpoint accepts one ABI report and discloses an APK only when ready', () async {
    final server = await PairingServer.start();
    final client = HttpClient();
    final url = server.url('127.0.0.1');
    try {
      final initial = await (await client.getUrl(url)).close();
      expect(initial.statusCode, HttpStatus.ok);
      expect(
        jsonDecode(await utf8.decoder.bind(initial).join()),
        containsPair('state', 'building'),
      );

      final report = await client.postUrl(url);
      report.headers.contentType = ContentType.json;
      report.write(
        jsonEncode({
          'abis': ['arm64-v8a', 'armeabi-v7a'],
        }),
      );
      final response = await report.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(await server.waitForPhone(), ['arm64-v8a', 'armeabi-v7a']);

      final duplicate = await client.postUrl(url);
      duplicate.headers.contentType = ContentType.json;
      duplicate.write(
        jsonEncode({
          'abis': ['arm64-v8a'],
        }),
      );
      expect((await duplicate.close()).statusCode, HttpStatus.conflict);

      final apk = Uri.parse('http://127.0.0.1:9999/only-this-apk');
      server.publishDownload(apk);
      final ready = await (await client.getUrl(url)).close();
      final body = jsonDecode(await utf8.decoder.bind(ready).join());
      expect(body, containsPair('state', 'ready'));
      expect(body, containsPair('downloadUrl', apk.toString()));

      final wrongToken = url.replace(
        queryParameters: {'airreload_pairing': '1', 'token': 'x' * 43},
      );
      expect(
        (await (await client.getUrl(wrongToken)).close()).statusCode,
        HttpStatus.notFound,
      );
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}
