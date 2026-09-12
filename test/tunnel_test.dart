import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:airreload/src/tunnel.dart';
import 'package:test/test.dart';
import 'package:test/fake.dart';

class MemoryLink extends Fake implements WebSocket {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  @override
  void add(dynamic data) =>
      sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<void> close([int? code, String? reason]) async {
    unawaited(incoming.close());
  }

  void receive(Map<String, Object?> frame) => incoming.add(jsonEncode(frame));
}

class MemorySocket extends Fake implements Socket {
  final incoming = StreamController<Uint8List>();
  final written = <int>[];
  bool destroyed = false;
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void add(List<int> data) => written.addAll(data);
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    destroyed = true;
    unawaited(incoming.close());
  }
}

void main() {
  test('host handshake routes binary data and bounds outgoing frames without network listeners', () async {
    final link = MemoryLink();
    final socket = MemorySocket();
    final host = Tunnel(link);
    final running = host.run();
    final attached = host.attach(socket);
    expect(link.sent.single, {'op': 'open', 'id': 1});
    link.receive({'op': 'ready', 'id': 1});
    await attached;
    socket.incoming.add(
      Uint8List.fromList(List<int>.generate(70000, (i) => i % 256)),
    );
    await Future<void>.delayed(Duration.zero);
    final frames = link.sent.where((f) => f['op'] == 'data').toList();
    expect(frames, hasLength(3));
    expect(frames.map((f) => base64Decode(f['data'] as String).length), [
      32768,
      32768,
      4464,
    ]);
    link.receive({
      'op': 'data',
      'id': 1,
      'data': base64Encode([0, 128, 255]),
    });
    await Future<void>.delayed(Duration.zero);
    expect(socket.written, [0, 128, 255]);
    link.receive({'op': 'close', 'id': 1});
    await Future<void>.delayed(Duration.zero);
    expect(socket.destroyed, isTrue);
    await host.close();
    await running;
  });
  test('host rejects peer-initiated channels', () async {
    final link = MemoryLink();
    final host = Tunnel(link);
    final running = host.run();
    final assertion = expectLater(running, throwsFormatException);
    link.receive({'op': 'open', 'id': 1});
    await assertion;
  });
  test('host rejects oversized frames and destroys active sockets', () async {
    final link = MemoryLink();
    final socket = MemorySocket();
    final host = Tunnel(link);
    final running = host.run();
    final assertion = expectLater(running, throwsFormatException);
    final attached = host.attach(socket);
    link.receive({'op': 'ready', 'id': 1});
    await attached;
    link.incoming.add('x' * 100001);
    await assertion;
    expect(socket.destroyed, isTrue);
  });
}
