import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Multiplexes VM service TCP streams over an authenticated WSS connection.
///
/// The app can open sockets only to the VM service's fixed loopback port.
class Tunnel {
  Tunnel(this.link, {this.vmPort, InternetAddress? vmAddress})
    : vmAddress = vmAddress ?? InternetAddress.loopbackIPv4;
  final WebSocket link;
  final int? vmPort;
  final InternetAddress vmAddress;
  final Map<int, Socket> _sockets = {};
  final Map<int, Completer<void>> _opening = {};
  int _nextId = 0;
  bool _closed = false;

  void _send(Map<String, Object?> frame) {
    if (!_closed) link.add(jsonEncode(frame));
  }

  Future<void> attach(Socket socket) async {
    if (_closed || _sockets.length >= 32) {
      socket.destroy();
      return;
    }
    final id = ++_nextId;
    _sockets[id] = socket;
    final ready = Completer<void>();
    _opening[id] = ready;
    _send({'op': 'open', 'id': id});
    try {
      await ready.future.timeout(const Duration(seconds: 10));
      if (!_closed && _sockets.containsKey(id)) _readSocket(id, socket);
    } catch (_) {
      _drop(id);
      _send({'op': 'close', 'id': id});
    } finally {
      _opening.remove(id);
    }
  }

  void _readSocket(int id, Socket socket) {
    socket.listen(
      (bytes) {
        // Keep frames bounded, even when the operating system gives us large reads.
        for (var start = 0; start < bytes.length; start += 32768) {
          final end = (start + 32768).clamp(0, bytes.length);
          _send({
            'op': 'data',
            'id': id,
            'data': base64Encode(bytes.sublist(start, end)),
          });
        }
      },
      onDone: () {
        _send({'op': 'close', 'id': id});
        _drop(id);
      },
      onError: (Object _) {
        _send({'op': 'close', 'id': id});
        _drop(id);
      },
    );
  }

  void _drop(int id) {
    _sockets.remove(id)?.destroy();
    final pending = _opening.remove(id);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Tunnel channel closed'));
    }
  }

  Future<void> run() async {
    try {
      await for (final raw in link) {
        if (raw is! String || raw.length > 100000) {
          throw const FormatException('Invalid frame');
        }
        final message = jsonDecode(raw) as Map<String, dynamic>;
        final id = message['id'] as int;
        switch (message['op']) {
          case 'open':
            if (vmPort == null ||
                _sockets.length >= 32 ||
                _sockets.containsKey(id)) {
              throw const FormatException('Invalid channel request');
            }
            try {
              final socket = await Socket.connect(
                vmAddress,
                vmPort!,
                timeout: const Duration(seconds: 5),
              );
              _sockets[id] = socket;
              _send({'op': 'ready', 'id': id});
              _readSocket(id, socket);
            } catch (_) {
              _send({'op': 'close', 'id': id});
            }
          case 'ready':
            final pending = _opening[id];
            if (pending != null && !pending.isCompleted) pending.complete();
          case 'data':
            final socket = _sockets[id];
            if (socket != null) {
              socket.add(base64Decode(message['data'] as String));
              await socket.flush();
            }
          case 'close':
            _drop(id);
          default:
            throw const FormatException('Unknown tunnel operation');
        }
      }
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final id in _sockets.keys.toList()) {
      _drop(id);
    }
    await link.close();
  }
}
