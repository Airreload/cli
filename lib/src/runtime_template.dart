const runtimeTemplate = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'config.dart';
import 'tunnel.dart';

void startAirreload() {
  assert(() { unawaited(_connectForever()); return true; }());
}

Future<void> _connectForever() async {
  while (true) {
    HttpClient? http;
    Tunnel? tunnel;
    try {
      var info = await developer.Service.getInfo();
      if (info.serverUri == null) {
        info = await developer.Service.controlWebServer(enable: true, silenceOutput: true);
      }
      final vm = info.serverUri;
      final address = vm == null ? null : InternetAddress.tryParse(vm.host);
      if (vm == null || address == null || !address.isLoopback || !vm.hasPort ||
          !RegExp(r'^/[A-Za-z0-9_=-]+/$').hasMatch(vm.path)) {
        throw StateError('Authenticated VM service unavailable');
      }
      http = HttpClient(context: SecurityContext(withTrustedRoots: false))
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, host, port) => base64Encode(cert.der) == certificatePin;
      var attemptFinished = false;
      final pending = WebSocket.connect(
        Uri(scheme: 'wss', host: computerHost, port: tunnelPort, path: '/connect').toString(),
        headers: {'Authorization': 'Bearer $sessionToken', 'x-airreload-vm-path': vm.path},
        customClient: http,
      ).then((link) async {
        if (attemptFinished) { await link.close(); throw StateError('Connection attempt expired'); }
        return link;
      });
      late WebSocket link;
      try { link = await pending.timeout(const Duration(seconds: 10)); }
      finally { attemptFinished = true; }
      link.pingInterval = const Duration(seconds: 10);
      tunnel = Tunnel(link, vmPort: vm.port, vmAddress: address);
      await tunnel.run();
    } catch (_) {
      // Connection failures must not terminate the app.
    } finally {
      http?.close(force: true);
      if (tunnel != null) {
        try { await tunnel.close().timeout(const Duration(seconds: 2), onTimeout: () {}); } catch (_) {}
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}
''';
