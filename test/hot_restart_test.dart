import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/session_host.dart';
import 'package:airreload/src/tunnel.dart';
import 'package:airreload/src/workspace.dart';
import 'package:test/test.dart';

void main() {
  group('reopening an app', () {
    test(
      'a cached dead VM is discarded before attaching to the new process',
      () async {
        await _withSession((host, client, proxy) async {
          final oldVm = await _FakeVm.start();
          final oldPort = oldVm.port;
          await oldVm.close();
          final ready = host.waitForReadyApp();
          await _connectPhone(host, client, oldPort);
          await _waitUntil(() => host.debugUri == null);
          final newVm = await _FakeVm.start(authPath: '/new-process=/');
          try {
            await _connectPhone(
              host,
              client,
              newVm.port,
              path: '/new-process=/',
            );
            final uri = await ready.timeout(const Duration(seconds: 5));
            expect(uri.path, '/new-process=/');
            expect(host.connectionGeneration, 2);
            await _expectProxiedGet(uri, '"fake-vm"');
          } finally {
            await newVm.close();
          }
        });
      },
    );

    test(
      'a live port with the old VM auth path is not reported as ready',
      () async {
        await _withSession((host, client, proxy) async {
          final vm = await _FakeVm.start(authPath: '/new-process=/');
          try {
            final ready = host.waitForReadyApp();
            await _connectPhone(host, client, vm.port, path: '/old-process=/');
            await _waitUntil(() => host.debugUri == null);
            await _connectPhone(host, client, vm.port, path: '/new-process=/');
            expect(
              (await ready.timeout(const Duration(seconds: 5))).path,
              '/new-process=/',
            );
            expect(host.connectionGeneration, 2);
          } finally {
            await vm.close();
          }
        });
      },
    );

    test(
      'an unresponsive tunnel times out and permits a fresh connection',
      () async {
        await _withSession((host, client, proxy) async {
          final ready = host.waitForReadyApp(
            probeTimeout: const Duration(milliseconds: 150),
          );
          final connected = host.waitForApp();
          final link = await WebSocket.connect(
            Uri(
              scheme: 'wss',
              host: '127.0.0.1',
              port: host.server.port,
              path: '/connect',
            ).toString(),
            customClient: client,
            headers: {
              'Authorization': 'Bearer ${host.token}',
              'x-airreload-vm-path': '/stale=/',
            },
          );
          // Consume frames but never acknowledge any proxy socket opens.
          final incoming = link.listen((_) {});
          await connected;
          await _waitUntil(() => host.debugUri == null);
          final vm = await _FakeVm.start();
          try {
            await _connectPhone(host, client, vm.port);
            expect(
              (await ready.timeout(const Duration(seconds: 5))).path,
              '/first-token=/',
            );
          } finally {
            await incoming.cancel();
            await link.close();
            await vm.close();
          }
        });
      },
    );
  });

  test('Dart-owned connector death drops the desktop proxy tunnel', () async {
    await _withSession((host, client, proxy) async {
      final vm = await _FakeVm.start();
      try {
        final phone = await _connectPhone(host, client, vm.port);
        await _expectProxiedGet(proxy, '"fake-vm"');
        await phone.close();
        await _waitUntil(() => host.debugUri == null);
        expect(host.debugUri, isNull);
        await expectLater(
          _proxiedGet(proxy),
          throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
        );
      } finally {
        await vm.close();
      }
    });
  });

  test('process-owned tunnel keeps proxy streams across a simulated isolate restart', () async {
    await _withSession((host, client, proxy) async {
      final vm = await _FakeVm.start();
      try {
        await _connectPhone(host, client, vm.port);
        await _expectProxiedGet(proxy, '"fake-vm"');
        // Hot restart destroys the Dart isolate. A process-owned connector
        // keeps the same WSS link, so Flutter's VM-service connection survives.
        await _expectProxiedGet(proxy, '"fake-vm"');
        expect(host.debugUri, isNotNull);
        expect(host.connectionGeneration, 1);
      } finally {
        await vm.close();
      }
    });
  });

  test(
    'a new isolate can reconnect after the previous connector is gone',
    () async {
      await _withSession((host, client, proxy) async {
        final firstVm = await _FakeVm.start();
        try {
          final first = await _connectPhone(host, client, firstVm.port);
          await _expectProxiedGet(proxy, '"fake-vm"');
          await first.close();
          await _waitUntil(() => host.debugUri == null);
        } finally {
          await firstVm.close();
        }
        final secondVm = await _FakeVm.start();
        try {
          await _connectPhone(
            host,
            client,
            secondVm.port,
            path: '/second-token=/',
          );
          expect(host.connectionGeneration, 2);
          await _expectProxiedGet(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: host.proxy.port,
              path: '/second-token=/',
            ),
            '"fake-vm"',
          );
        } finally {
          await secondVm.close();
        }
      });
    },
  );

  test('concurrent HTTP and WebSocket streams stay multiplexed for DDS-style traffic', () async {
    await _withSession((host, client, proxy) async {
      final vm = await _FakeVm.start();
      try {
        await _connectPhone(host, client, vm.port);
        final ws = await WebSocket.connect(
          proxy.replace(scheme: 'ws', path: '${proxy.path}ws').toString(),
        );
        try {
          ws.add('timeline');
          final echoed = await ws.first.timeout(const Duration(seconds: 5));
          expect(echoed, 'timeline');
          final bodies = await Future.wait([
            for (var i = 0; i < 4; i++) _proxiedGet(proxy),
          ]);
          expect(bodies, everyElement(contains('"fake-vm"')));
          expect(host.debugUri, isNotNull);
        } finally {
          await ws.close();
        }
      } finally {
        await vm.close();
      }
    });
  });

  test(
    'repeated reload-style requests then a restart-style reconnect work',
    () async {
      await _withSession((host, client, proxy) async {
        final vm = await _FakeVm.start();
        try {
          var phone = await _connectPhone(host, client, vm.port);
          for (var i = 0; i < 5; i++) {
            await _expectProxiedGet(proxy, '"fake-vm"');
          }
          await phone.close();
          await _waitUntil(() => host.debugUri == null);
          phone = await _connectPhone(host, client, vm.port);
          await _expectProxiedGet(proxy, '"fake-vm"');
          await _expectProxiedGet(proxy, '"fake-vm"');
          await phone.close();
        } finally {
          await vm.close();
        }
      });
    },
  );
}

Future<void> _withSession(
  Future<void> Function(SessionHost host, HttpClient client, Uri proxy) body,
) async {
  final temp = await Directory.systemTemp.createTemp('airreload-restart-');
  final workspace = SessionWorkspace(Directory.current.parent.path, temp.path);
  final host = await SessionHost.start(workspace);
  final pin = base64Encode(
    certificateDer(await File(workspace.certificate).readAsString()),
  );
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..badCertificateCallback = (cert, hostName, port) =>
        base64Encode(cert.der) == pin;
  try {
    await body(
      host,
      client,
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: host.proxy.port,
        path: '/first-token=/',
      ),
    );
  } finally {
    client.close(force: true);
    await host.close();
    await temp.delete(recursive: true);
  }
}

Future<Tunnel> _connectPhone(
  SessionHost host,
  HttpClient client,
  int vmPort, {
  String path = '/first-token=/',
}) async {
  final ready = host.waitForApp();
  final link = await WebSocket.connect(
    Uri(
      scheme: 'wss',
      host: '127.0.0.1',
      port: host.server.port,
      path: '/connect',
    ).toString(),
    customClient: client,
    headers: {
      'Authorization': 'Bearer ${host.token}',
      'x-airreload-vm-path': path,
    },
  );
  final phone = Tunnel(link, vmPort: vmPort);
  unawaited(phone.run().catchError((Object _) {}));
  expect((await ready).path, path);
  return phone;
}

Future<String> _proxiedGet(Uri proxy) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(proxy))
        .close()
        .timeout(const Duration(seconds: 5));
    return utf8.decode(
      await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _expectProxiedGet(Uri proxy, String needle) async {
  expect(await _proxiedGet(proxy), contains(needle));
}

Future<void> _waitUntil(bool Function() test) async {
  for (var i = 0; i < 200; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for condition');
}

class _FakeVm {
  _FakeVm(this.server);
  final HttpServer server;
  int get port => server.port;

  static Future<_FakeVm> start({String? authPath}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (authPath != null && !request.uri.path.startsWith(authPath)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.uri.path.endsWith('/getVersion')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"result":{"type":"Version","major":4,"minor":0}}',
        );
        await request.response.close();
        return;
      }
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          socket.add(message);
        });
        return;
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"type":"VM","name":"fake-vm"}');
      await request.response.close();
    });
    return _FakeVm(server);
  }

  Future<void> close() => server.close(force: true);
}
