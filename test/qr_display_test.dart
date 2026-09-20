import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/qr_display.dart';
import 'package:airreload/src/session_host.dart';
import 'package:test/test.dart';

void main() {
  test('live page follows pairing, build, ready and failure without exposing APK URLs', () async {
    final pairing = await PairingServer.start();
    final phone = pairing.waitForPhone();
    final page = await PairingPageServer.start(
      pairing.url('192.0.2.1'),
      () => pairing.pageState,
    );
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await page.close();
      await pairing.close();
    });
    final statusUrl = page.url.replace(path: '${page.url.path}/status');
    Future<Map<String, dynamic>> status() async {
      final response = await (await client.getUrl(statusUrl)).close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value('cache-control'), 'no-store');
      expect(response.headers.value('access-control-allow-origin'), isNull);
      return jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>;
    }

    expect(page.url.host, '127.0.0.1');
    final response = await (await client.getUrl(page.url)).close();
    expect(response.headers.contentType?.mimeType, 'text/html');
    final html = await utf8.decoder.bind(response).join();
    expect(html, contains('content="dark"'));
    expect(html, contains(qrSvg(pairing.url('192.0.2.1').toString())));
    expect(html, contains("location.pathname + '/status'"));
    expect(html, isNot(contains('Pairing address:')));
    expect(html, isNot(contains('passkey')));
    expect(await status(), containsPair('state', 'waiting'));

    final invalid = await client.postUrl(pairing.url('127.0.0.1'));
    invalid.write('{"abis":[]}');
    expect((await invalid.close()).statusCode, HttpStatus.badRequest);
    expect(await status(), containsPair('state', 'waiting'));
    final report = await client.postUrl(pairing.url('127.0.0.1'));
    report.write('{"abis":["arm64-v8a"]}');
    expect((await report.close()).statusCode, HttpStatus.ok);
    await phone;
    expect(await status(), containsPair('state', 'building'));
    pairing.publishDownload(Uri.parse('http://192.0.2.1/secret/app.apk'));
    final ready = await status();
    expect(ready, containsPair('state', 'ready'));
    expect(ready, isNot(contains('downloadUrl')));
    pairing.fail('Build failed.');
    expect(await status(), {'state': 'error', 'message': 'Build failed.'});

    for (final uri in [
      page.url.replace(path: '/'),
      page.url.replace(path: '${page.url.path}/other'),
      page.url.replace(query: 'anything=1'),
    ]) {
      expect(
        (await (await client.getUrl(uri)).close()).statusCode,
        HttpStatus.notFound,
      );
    }
    final wrongHost = await client.getUrl(statusUrl);
    wrongHost.headers.set(HttpHeaders.hostHeader, 'untrusted.example');
    expect((await wrongHost.close()).statusCode, HttpStatus.notFound);
    final post = await client.postUrl(statusUrl);
    expect((await post.close()).statusCode, HttpStatus.methodNotAllowed);
  });

  group('QR image', () {
    for (final url in [
      'http://192.168.1.2:8080/app.apk',
      'http://192.168.100.200:65535/${'aB_9-' * 9}/app-debug.apk',
    ]) {
      test('keeps square modules and a clear border for $url', () {
        final svg = qrSvg(url);
        final bounds = RegExp(r'viewBox="0 0 (\d+) (\d+)"').firstMatch(svg)!;
        final size = int.parse(bounds[1]!);
        expect(bounds[1], bounds[2]);
        expect(svg, contains('width="${size * 10}" height="${size * 10}"'));
        expect(
          svg,
          contains('<rect width="$size" height="$size" fill="#fff"/>'),
        );
        final modules = RegExp(r'M(\d+) (\d+)h1v1h-1z').allMatches(svg);
        expect(modules, isNotEmpty);
        for (final module in modules) {
          expect(int.parse(module[1]!), inInclusiveRange(4, size - 5));
          expect(int.parse(module[2]!), inInclusiveRange(4, size - 5));
        }
        expect(svg, contains('fill="#000"'));
        expect(svg, contains('shape-rendering="crispEdges"'));
      });
    }
  });

  test(
    'install page embeds its image and preserves the exact download URL',
    () {
      final url = Uri.parse(
        'http://192.0.2.1:1234/token/app-debug.apk?a=1&b=2',
      );
      final page = qrDownloadPage(url);
      expect(page, contains(qrSvg(url.toString())));
      expect(
        page,
        contains('href="${const HtmlEscape().convert(url.toString())}"'),
      );
      expect(page, contains('same network'));
      expect(page, contains('current session'));
      expect(page, isNot(contains('<script')));
      expect(page, isNot(contains('<img')));
    },
  );
}
