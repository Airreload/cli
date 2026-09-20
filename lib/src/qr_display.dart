import 'dart:convert';
import 'dart:io';

import 'package:qr/qr.dart';

String qrSvg(String data) {
  final image = QrImage(QrCode(payload: QrPayload.fromString(data)));
  const border = 4;
  final size = image.moduleCount + border * 2;
  final modules = StringBuffer();
  for (var y = 0; y < image.moduleCount; y++) {
    for (var x = 0; x < image.moduleCount; x++) {
      if (image.isDark(y, x)) {
        modules.write('M${x + border} ${y + border}h1v1h-1z');
      }
    }
  }
  // Integer-sized modules and an opaque quiet zone avoid terminal font,
  // line-height, theme, and Unicode rendering differences.
  return '<svg xmlns="http://www.w3.org/2000/svg" '
      'viewBox="0 0 $size $size" width="${size * 10}" height="${size * 10}" '
      'shape-rendering="crispEdges" role="img" aria-label="Scan to download your app">'
      '<rect width="$size" height="$size" fill="#fff"/>'
      '<path d="$modules" fill="#000"/></svg>';
}

String qrDownloadPage(Uri download) {
  final url = const HtmlEscape().convert(download.toString());
  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Airreload — Install your app</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 20px; background: #f4f5f7; color: #151719;
      font: 17px/1.5 system-ui, sans-serif; text-align: center; }
    main { max-width: 720px; margin: auto; }
    h1 { margin-bottom: 8px; font-size: 30px; }
    p { margin: 12px 0; }
    svg { display: block; max-width: 100%; height: auto; margin: 24px auto; }
    a { color: #164ca4; overflow-wrap: anywhere; }
    .hint { color: #4e535a; font-size: 15px; }
  </style>
</head>
<body><main>
  <h1>Install your app</h1>
  <p>Scan with your Android phone’s camera, install the APK, then open your app.</p>
  ${qrSvg(download.toString())}
  <p>Keep your phone and computer on the same network.</p>
  <p class="hint">Keep the Airreload terminal running while you install and use the app.
    This code works only for the current session.</p>
  <p><a href="$url">Download APK</a></p>
  <p class="hint">Or open this address on your phone:<br><a href="$url">$url</a></p>
</main></body>
</html>
''';
}

String qrPairingPage(Uri pairing) {
  final url = const HtmlEscape().convert(pairing.toString());
  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Airreload — Pair phone</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 20px; background: #f4f5f7; color: #151719;
      font: 17px/1.5 system-ui, sans-serif; text-align: center; }
    main { max-width: 720px; margin: auto; }
    h1 { margin-bottom: 8px; font-size: 30px; }
    p { margin: 12px 0; }
    svg { display: block; max-width: 100%; height: auto; margin: 24px auto; }
    .hint { color: #4e535a; font-size: 15px; }
  </style>
</head>
<body><main>
  <h1>Pair Airreload Go</h1>
  <p>Scan this code in Airreload Go and confirm pairing. It reports only your phone’s supported Android ABIs, then Airreload builds the matching debug APK.</p>
  ${qrSvg(pairing.toString())}
  <p>Keep your phone and computer on the same trusted network.</p>
  <p class="hint">This short-lived pairing code authorizes one phone and does not download or install anything until you confirm it in Airreload Go.</p>
  <p class="hint">Keep the Airreload terminal running during pairing, installation, and development.</p>
  <p class="hint">Pairing address:<br>$url</p>
</main></body>
</html>
''';
}

Future<bool> openQrPage(File page) async {
  if (Platform.environment.containsKey('SSH_CONNECTION') ||
      Platform.environment.containsKey('SSH_TTY')) {
    return false;
  }
  final String executable;
  final List<String> arguments;
  if (Platform.isMacOS) {
    executable = '/usr/bin/open';
    arguments = [page.absolute.path];
  } else if (Platform.isLinux) {
    executable = 'xdg-open';
    arguments = [page.absolute.uri.toString()];
  } else if (Platform.isWindows) {
    executable = 'rundll32';
    arguments = ['url.dll,FileProtocolHandler', page.absolute.uri.toString()];
  } else {
    return false;
  }
  try {
    final process = await Process.start(executable, arguments);
    // Drain opener output so desktop-launch errors cannot disrupt the session.
    final results =
        await Future.wait([
          process.exitCode,
          process.stdout.drain<int>(0),
          process.stderr.drain<int>(0),
        ]).timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill();
            return [-1];
          },
        );
    return results.first == 0;
  } on ProcessException {
    return false;
  }
}
