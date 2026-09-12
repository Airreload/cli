import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const cliVersion = '0.2.0-beta.1';
const sdkCommit = '558d79bc24bfcadeff45b93a7d971ae670a1e8fc';

class Workspace {
  Workspace(this.root);
  final String root;
  String get flutter => p.join(root, 'flutter', 'bin', 'flutter');
  String get state => p.join(root, 'cli', '.airreload');
  String get certificate => p.join(state, 'host-cert.pem');
  String get key => p.join(state, 'host-key.pem');
  String get session => p.join(state, 'session.json');

  Future<void> preparePrivateDirectory() async {
    await Directory(state).create(recursive: true);
    await _chmod('700', state);
  }

  Future<void> writeSession(Map<String, Object?> value) async {
    final temporary = File('$session.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await _chmod('600', temporary.path);
    await temporary.rename(session);
  }

  Future<void> ensureIdentity() async {
    final hasCertificate = await File(certificate).exists();
    final hasKey = await File(key).exists();
    if (hasCertificate && hasKey) return;
    if (hasCertificate || hasKey) {
      throw StateError(
        'Incomplete host identity in $state. Restore the matching certificate and key.',
      );
    }
    final temporary = await Directory(state).createTemp('identity-');
    try {
      await _chmod('700', temporary.path);
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        p.join(temporary.path, 'key.pem'),
        '-out',
        p.join(temporary.path, 'cert.pem'),
        '-days',
        '365',
        '-subj',
        '/CN=Airreload local development',
      ]);
      if (result.exitCode != 0) {
        throw StateError('OpenSSL could not generate the host identity.');
      }
      await _chmod('600', p.join(temporary.path, 'key.pem'));
      await _chmod('600', p.join(temporary.path, 'cert.pem'));
      await File(p.join(temporary.path, 'key.pem')).rename(key);
      await File(p.join(temporary.path, 'cert.pem')).rename(certificate);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> activeSession() async {
    if (!await File(session).exists()) {
      throw StateError('Host is not running. Start it with: airreload host');
    }
    final data =
        jsonDecode(await File(session).readAsString()) as Map<String, dynamic>;
    final port = data['port'] as int;
    if (port < 1 || port > 65535) {
      throw StateError('Invalid host session port.');
    }
    final pem = await File(certificate).readAsString();
    final pin = certificateDer(pem);
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 2)
      ..badCertificateCallback = (cert, host, port) =>
          constantTimeEqual(base64Encode(cert.der), base64Encode(pin));
    try {
      final request = await client.getUrl(
        Uri(scheme: 'https', host: '127.0.0.1', port: port, path: '/status'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${data['token']}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Host session is no longer valid. Restart this workspace host.',
        );
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 3));
      final status = jsonDecode(body) as Map<String, dynamic>;
      return {...data, 'debugUrl': status['debugUrl']};
    } on SocketException {
      throw StateError('Saved host session is offline. Start airreload host.');
    } finally {
      client.close(force: true);
    }
  }
}

Future<void> _chmod(String mode, String path) async {
  final result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw StateError('Could not restrict access to $path.');
  }
}

String randomToken() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
}

bool constantTimeEqual(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var mismatch = left.length ^ right.length;
  for (var i = 0; i < left.length; i++) {
    mismatch |= left[i] ^ (i < right.length ? right[i] : 0);
  }
  return mismatch == 0;
}

List<int> certificateDer(String pem) =>
    base64Decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''));
String certificateFingerprint(String pem) =>
    sha256.convert(certificateDer(pem)).toString();

bool validVmPath(String? path) =>
    path != null && RegExp(r'^/[A-Za-z0-9_=-]+/$').hasMatch(path);

Uri validateDebugUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !validVmPath(uri.path)) {
    throw StateError(
      'Host has no valid authenticated loopback VM endpoint. Connect a compatible debug app first.',
    );
  }
  return uri;
}

List<String> attachArguments(String url, String? target) => [
  'attach',
  '--airreload',
  '--debug-url=${validateDebugUrl(url)}',
  '--no-dds',
  '--no-devtools',
  if (target != null) '--target=$target',
];
