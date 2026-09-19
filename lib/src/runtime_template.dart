const runtimeTemplate = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Publishes the VM-service URI for the process-owned Android tunnel.
///
/// The authenticated WSS connector must not live in this isolate: Flutter hot
/// restart destroys and recreates it, which would drop the transport carrying
/// the VM service. The debug-only Android native component keeps that
/// connection alive across isolate replacement.
void startAirreload() {
  assert(() { unawaited(_publishVmEndpointForever()); return true; }());
}

Future<void> _publishVmEndpointForever() async {
  while (true) {
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
      await File('${Directory.systemTemp.path}/airreload-vm.json').writeAsString(
        jsonEncode({'host': address.address, 'port': vm.port, 'path': vm.path}),
        flush: true,
      );
    } catch (_) {
      // Discovery failures must not terminate the app.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}
''';
