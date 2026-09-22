import 'dart:async';
import 'dart:convert';
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

  /// A tunnel handshake alone does not prove its advertised VM is alive. An
  /// older APK can reconnect using a cached port/auth path from its last process.
  Future<Uri> waitForReadyApp({
    Duration probeTimeout = const Duration(seconds: 5),
  }) async {
    while (!_closed) {
      final uri = await waitForApp();
      final generation = connectionGeneration;
      final tunnel = _current;
      if (await _vmResponds(uri, probeTimeout)) {
        if (identical(_current, tunnel) && generation == connectionGeneration) {
          return uri;
        }
        continue;
      }
      if (identical(_current, tunnel) && generation == connectionGeneration) {
        // Force the phone to rediscover its VM instead of leaving Flutter
        // attached indefinitely to an authenticated but unusable tunnel.
        _current = null;
        debugUri = null;
        if (!_closed) _connections.add(null);
        await tunnel?.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
    }
    throw StateError('The Airreload session ended.');
  }

  Future<bool> _vmResponds(Uri uri, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final request = await client.getUrl(uri.resolve('getVersion'));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) return false;
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16384) return false;
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        return decoded is Map<String, dynamic> &&
            decoded['result'] is Map<String, dynamic> &&
            (decoded['result'] as Map<String, dynamic>)['type'] == 'Version';
      })().timeout(timeout);
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
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

/// A deliberately tiny, one-device pairing endpoint used before an APK exists.
///
/// This is HTTP because Go cannot pin the per-session TLS certificate until it
/// has downloaded the APK that contains it.  The endpoint is safe to expose on
/// a trusted LAN only: both an unguessable route and a 256-bit bearer token are
/// required, it accepts one ABI report, and it exposes no files or directories.
class PairingServer {
  PairingServer._(this.server, this.route, this.token) {
    // A preparation failure can close the server before waitForPhone() is
    // reached. Keep that close error available to callers without letting an
    // otherwise unobserved future mask the actual preparation error.
    _phone.future.ignore();
    _subscription = server.listen((request) => unawaited(_respond(request)));
  }

  final HttpServer server;
  final String route;
  final String token;
  late final StreamSubscription<HttpRequest> _subscription;
  final _phone = Completer<List<String>>();
  List<String>? _abis;
  Uri? _download;
  String? _failure;
  bool _closed = false;

  static Future<PairingServer> start() async {
    return PairingServer._(
      await HttpServer.bind(InternetAddress.anyIPv4, 0),
      '/pair/${randomToken().replaceAll('=', '')}',
      randomToken(),
    );
  }

  /// This complete URL, rather than an APK URL, is what is encoded in the QR.
  Uri url(String host) => Uri(
    scheme: 'http',
    host: host,
    port: server.port,
    path: route,
    queryParameters: {'airreload_pairing': '1', 'token': token},
  );

  Future<List<String>> waitForPhone() => _phone.future;

  Map<String, String> get pageState {
    if (_failure case final message?) {
      return {'state': 'error', 'message': message};
    }
    if (_download != null) {
      return {
        'state': 'ready',
        'message': 'Airreload Go will download your app automatically. Approve installation on your phone, then open your app.',
      };
    }
    if (_abis != null) {
      return {
        'state': 'building',
        'message': 'Your phone is connected. The download will start automatically when the build is ready.',
      };
    }
    return {'state': 'waiting', 'message': ''};
  }

  void publishDownload(Uri url) {
    if (_abis == null) throw StateError('Cannot publish before a phone pairs.');
    _download = url;
  }

  void fail(String message) {
    _failure = message;
  }

  bool _authorized(HttpRequest request) {
    final parameters = request.uri.queryParameters;
    return request.uri.path == route &&
        parameters.length == 2 &&
        parameters['airreload_pairing'] == '1' &&
        parameters.containsKey('token') &&
        constantTimeEqual(parameters['token']!, token);
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      if (!_authorized(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (request.method == 'POST') {
        if (_abis != null) {
          await _json(request, HttpStatus.conflict, {
            'state': 'error',
            'message': 'This pairing code has already been used.',
          });
          return;
        }
        if (request.contentLength > 16 * 1024) throw const FormatException();
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 16 * 1024) throw const FormatException();
        }
        final body = utf8.decode(bytes);
        final decoded = jsonDecode(body);
        if (decoded is! Map || decoded['abis'] is! List) {
          throw const FormatException();
        }
        final abis = <String>{
          for (final abi in decoded['abis'] as List)
            if (abi is String && abi.isNotEmpty && abi.length <= 64) abi,
        }.toList(growable: false);
        if (abis.isEmpty) throw const FormatException();
        _abis = abis;
        _phone.complete(abis);
        await _state(request);
        return;
      }
      if (request.method == 'GET') {
        await _state(request);
        return;
      }
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
    } on FormatException {
      await _json(request, HttpStatus.badRequest, {
        'state': 'error',
        'message': 'The pairing request did not include a valid ABI list.',
      });
    } on Object {
      await request.response.close().catchError((Object _) {});
    }
  }

  Future<void> _state(HttpRequest request) async {
    if (_failure case final message?) {
      await _json(request, HttpStatus.ok, {
        'state': 'error',
        'message': message,
      });
    } else if (_download case final url?) {
      await _json(request, HttpStatus.ok, {
        'state': 'ready',
        'message': 'Your debug APK is ready. Airreload Go will download it automatically.',
        'downloadUrl': url.toString(),
      });
    } else {
      await _json(request, HttpStatus.ok, {
        'state': 'building',
        'message': 'Airreload is selecting an Android target and building your debug APK.',
      });
    }
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, String> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_phone.isCompleted) {
      _phone.completeError(StateError('The Airreload pairing session ended.'));
    }
    await _subscription.cancel();
    await server.close(force: true);
  }
}
