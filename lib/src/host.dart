import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel.dart';
import 'workspace.dart';

int connectionStatus({
  required String? authorization,
  required String token,
  required String? vmPath,
  required bool occupied,
  required bool upgrade,
}) {
  if (authorization == null ||
      !constantTimeEqual(authorization, 'Bearer $token')) {
    return HttpStatus.unauthorized;
  }
  if (!validVmPath(vmPath)) return HttpStatus.badRequest;
  if (occupied || !upgrade) return HttpStatus.conflict;
  return HttpStatus.switchingProtocols;
}

Future<void> runHost(Workspace workspace, int port) async {
  await workspace.preparePrivateDirectory();
  final lock = await File('${workspace.state}/host.lock')
      .open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
  } on FileSystemException {
    await lock.close();
    throw StateError(
      'This workspace already has a running host. Use airreload status.',
    );
  }
  HttpServer? server;
  ServerSocket? proxy;
  Tunnel? current;
  String? debugUrl;
  final subscriptions = <StreamSubscription<Object?>>[];
  final stopped = Completer<void>();
  var wroteSession = false;
  try {
    await workspace.ensureIdentity();
    final context = SecurityContext()
      ..useCertificateChain(workspace.certificate)
      ..usePrivateKey(workspace.key);
    server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      context,
    );
    proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxyPort = proxy.port;
    final token = randomToken();
    await workspace.writeSession({
      'port': server.port,
      'proxyPort': proxyPort,
      'token': token,
      'pid': pid,
    });
    wroteSession = true;
    stdout.writeln(
      'Airreload host listening on TLS port ${server.port}. Ctrl-C stops it.',
    );
    stdout.writeln(
      'In another terminal: airreload pair --host <computer-lan-ip>',
    );
    stdout.writeln(
      'The compatible Android ARM64 debug app must pin ${workspace.certificate}.',
    );
    subscriptions.add(
      proxy.listen((socket) {
        final tunnel = current;
        if (tunnel == null) {
          socket.destroy();
        } else {
          unawaited(tunnel.attach(socket));
        }
      }),
    );
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      subscriptions.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    final activeServer = server;
    final serving = () async {
      await for (final request in activeServer) {
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        if (authorization == null ||
            !constantTimeEqual(authorization, 'Bearer $token')) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          continue;
        }
        if (request.uri.path == '/status' && request.method == 'GET') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'debugUrl': debugUrl}));
          await request.response.close();
          continue;
        }
        // Accept the legacy header for compatibility with older companions.
        final vmPath =
            request.headers.value('x-airreload-vm-path') ??
            request.headers.value('x-hotlink-vm-path');
        final status = request.uri.path == '/connect'
            ? connectionStatus(
                authorization: authorization,
                token: token,
                vmPath: vmPath,
                occupied: current != null,
                upgrade: WebSocketTransformer.isUpgradeRequest(request),
              )
            : HttpStatus.notFound;
        if (status != HttpStatus.switchingProtocols) {
          request.response.statusCode = status;
          await request.response.close();
          continue;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.pingInterval = const Duration(seconds: 15);
        final tunnel = Tunnel(socket);
        current = tunnel;
        debugUrl = Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: proxyPort,
          path: vmPath,
        ).toString();
        stdout.writeln(
          'App connected. Run airreload attach --project <matching-flutter-project>.',
        );
        unawaited(
          tunnel
              .run()
              .catchError((Object error) {
                stderr.writeln('Tunnel ended (${error.runtimeType}).');
              })
              .whenComplete(() {
                if (identical(current, tunnel)) {
                  current = null;
                  debugUrl = null;
                  stdout.writeln('App disconnected. Waiting for reconnection.');
                }
              }),
        );
      }
    }();
    await Future.any<void>([stopped.future, serving]);
  } finally {
    try {
      final tunnel = current;
      await Future.wait<void>([
        for (final subscription in subscriptions) subscription.cancel(),
        if (tunnel != null)
          tunnel.close().timeout(const Duration(seconds: 2), onTimeout: () {}),
        if (server != null) server.close(force: true).then((_) {}),
        if (proxy != null) proxy.close().then((_) {}),
      ]);
    } finally {
      try {
        if (wroteSession && await File(workspace.session).exists()) {
          await File(workspace.session).delete();
        }
      } finally {
        await lock.close();
      }
    }
  }
}
