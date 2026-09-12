import 'dart:convert';

import 'package:airreload/src/qr_display.dart';
import 'package:test/test.dart';

void main() {
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
