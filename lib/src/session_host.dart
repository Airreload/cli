import 'dart:async';
import 'dart:io';

import 'host.dart' show connectionStatus;
import 'tunnel.dart';
import 'workspace.dart';

class SessionWorkspace extends Workspace {
  SessionWorkspace(super.root, this.directory);
  final String directory;
  @override
  String get state => directory;
}

class SessionHost {
  SessionHost._(this.server, this.proxy, this.token) {
    _proxySubscription = proxy.listen((socket) {
      final tunnel = _current;
      if (tunnel == null) {
        socket.destroy();
      } else {
        unawaited(tunnel.attach(socket));
      }
    });
    _serving = _serve();
    unawaited(
      _serving.catchError((Object error) {
        if (!_closed) _connections.addError(error);
      }),
    );
  }
  final HttpServer server;
  final ServerSocket proxy;
  final String token;
  final _connections = StreamController<Uri?>.broadcast();
  late final StreamSubscription<Socket> _proxySubscription;
  late final Future<void> _serving;
  Tunnel? _current;
  Uri? debugUri;
  int connectionGeneration = 0;
  bool _closed = false;

  static Future<SessionHost> start(Workspace workspace) async {
    await workspace.preparePrivateDirectory();
    await workspace.ensureIdentity();
    final context = SecurityContext()
      ..useCertificateChain(workspace.certificate)
      ..usePrivateKey(workspace.key);
    final server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      0,
      context,
    );
    try {
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      return SessionHost._(server, proxy, randomToken());
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<Uri> waitForApp() async {
    if (debugUri case final uri?) return uri;
    return (await _connections.stream.firstWhere((uri) => uri != null))!;
  }

  Future<void> _serve() async {
    await for (final request in server) {
      final path = request.headers.value('x-airreload-vm-path');
      final status = request.uri.path == '/connect'
          ? connectionStatus(
              authorization: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
              token: token,
              vmPath: path,
              occupied: _current != null,
              upgrade: WebSocketTransformer.isUpgradeRequest(request),
            )
          : HttpStatus.notFound;
      if (status != HttpStatus.switchingProtocols) {
        request.response.statusCode = status;
        await request.response.close();
        continue;
      }
      final link = await WebSocketTransformer.upgrade(request);
      link.pingInterval = const Duration(seconds: 10);
      final tunnel = Tunnel(link);
      _current = tunnel;
      connectionGeneration++;
      debugUri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: proxy.port,
        path: path,
      );
      _connections.add(debugUri);
      unawaited(
        tunnel.run().catchError((Object _) {}).whenComplete(() {
          if (identical(_current, tunnel)) {
            _current = null;
            debugUri = null;
            if (!_closed) _connections.add(null);
          }
        }),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait<void>([
      _proxySubscription.cancel(),
      if (_current case final tunnel?)
        tunnel.close().timeout(const Duration(seconds: 2), onTimeout: () {}),
      server.close(force: true).then((_) {}),
      proxy.close().then((_) {}),
    ]);
    await _connections.close();
  }
}

class ApkServer {
  ApkServer._(this.server, this.apk, this.route) {
    _subscription = server.listen((request) => unawaited(_respond(request)));
  }
  final HttpServer server;
  final File apk;
  final String route;
  late final StreamSubscription<HttpRequest> _subscription;

  static Future<ApkServer> start(File apk) async {
    if (!await apk.exists()) {
      throw StateError('APK build did not produce the expected file.');
    }
    return ApkServer._(
      await HttpServer.bind(InternetAddress.anyIPv4, 0),
      apk,
      '/${randomToken().replaceAll('=', '')}/app-debug.apk',
    );
  }

  Uri url(String host) =>
      Uri(scheme: 'http', host: host, port: server.port, path: route);

  Future<void> _respond(HttpRequest request) async {
    try {
      if (request.uri.path != route ||
          request.uri.hasQuery ||
          !{'GET', 'HEAD'}.contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers
        ..contentType = ContentType(
          'application',
          'vnd.android.package-archive',
        )
        ..set(
          'Content-Disposition',
          'attachment; filename="airreload-debug.apk"',
        )
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      request.response.contentLength = await apk.length();
      if (request.method == 'GET') {
        await request.response.addStream(apk.openRead());
      }
      await request.response.close();
    } on Object {
      await request.response.close().catchError((Object _) {});
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await server.close(force: true);
  }
}
