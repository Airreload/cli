import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/host.dart';
import 'package:airreload/src/workspace.dart';
import 'package:test/test.dart';

void main() {
  test(
    'connection requires correct bearer, VM auth path and one WebSocket peer',
    () {
      int check({
        String? auth = 'Bearer synthetic',
        String? path = '/vm-token=/',
        bool occupied = false,
        bool upgrade = true,
      }) => connectionStatus(
        authorization: auth,
        token: 'synthetic',
        vmPath: path,
        occupied: occupied,
        upgrade: upgrade,
      );
      expect(check(), HttpStatus.switchingProtocols);
      for (final auth in [null, '', 'Bearer wrong', 'Bearer synthetic-extra']) {
        expect(check(auth: auth), HttpStatus.unauthorized);
      }
      for (final path in [
        null,
        '/',
        '//',
        '/token',
        '/token/extra/',
        '/token/?query',
      ]) {
        expect(check(path: path), HttpStatus.badRequest);
      }
      expect(check(occupied: true), HttpStatus.conflict);
      expect(check(upgrade: false), HttpStatus.conflict);
    },
  );
  test(
    'VM endpoint validation refuses external or unauthenticated services',
    () {
      expect(validateDebugUrl('http://127.0.0.1:50001/token=/').port, 50001);
      for (final url in [
        'http://127.0.0.1:50001/',
        'https://127.0.0.1:50001/token/',
        'http://127.0.0.1:0/token/',
        'http://127.0.0.1:65536/token/',
        'http://user@127.0.0.1:50001/token/',
        'http://127.0.0.1:50001/token/?q=1',
        'http://192.0.2.1:50001/token/',
      ]) {
        expect(() => validateDebugUrl(url), throwsStateError);
      }
    },
  );
  test(
    'pairing tokens contain 32 random bytes and comparisons reject mismatches',
    () {
      final first = randomToken();
      final second = randomToken();
      expect(base64Url.decode(first), hasLength(32));
      expect(first, isNot(second));
      expect(constantTimeEqual(first, first), isTrue);
      expect(constantTimeEqual(first, second), isFalse);
      expect(constantTimeEqual(first, '$first-extra'), isFalse);
    },
  );
  test(
    'private session writes restrict access and identity stays ungenerated',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'airreload-state-test-',
      );
      try {
        final workspace = Workspace(temporary.path);
        await workspace.preparePrivateDirectory();
        await workspace.writeSession({
          'token': 'synthetic-fixture',
          'port': 9443,
        });
        expect((await Directory(workspace.state).stat()).mode & 0x1ff, 0x1c0);
        expect((await File(workspace.session).stat()).mode & 0x1ff, 0x180);
        expect(await File(workspace.key).exists(), isFalse);
        expect(await File(workspace.certificate).exists(), isFalse);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );
}
