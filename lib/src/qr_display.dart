import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qr/qr.dart';

import 'workspace.dart' show randomToken;

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
      'shape-rendering="crispEdges" role="img" aria-label="Airreload QR code">'
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
  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Airreload — Pair phone</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; min-height: 100svh; padding: 48px 24px;
      display: grid; place-items: center; background: #17212b; color: #edf2f6;
      font: 16px/1.6 system-ui, sans-serif; text-align: center; }
    main { width: 100%; max-width: 420px; }
    [hidden] { display: none !important; }
    #qr { width: 264px; max-width: 100%; margin: 0 auto 32px;
      background: white; border-radius: 16px; overflow: hidden; }
    #qr svg { display: block; width: 100%; height: auto; }
    #result { width: 96px; height: 96px; margin: 0 auto 32px; border-radius: 50%;
      display: grid; place-items: center; background: #203b3c; color: #8addb8; }
    #result svg { width: 44px; height: 44px; }
    body[data-state="error"] #result { background: #402d35; color: #ffb4b4; }
    body[data-state="offline"] #result { background: #253442; color: #a7b9c8; }
    h1 { margin: 0 0 20px; font-size: 25px; line-height: 1.3; font-weight: 600; }
    ol { display: inline-block; text-align: left; margin: 0; padding-left: 24px; }
    li { padding: 3px 0 3px 4px; }
    #message { margin: 0; color: #bccad5; }
    .hint { color: #8e9eac; font-size: 13px; margin: 28px 0 0; }
    #status { display: flex; justify-content: center; align-items: center; gap: 9px;
      color: #70b9ed; font-size: 14px; margin: 24px 0 0; }
    #dot { width: 7px; height: 7px; background: currentColor; border-radius: 50%; }
    body[data-state="building"] #dot { width: 13px; height: 13px;
      background: none; border: 2px solid #38536a; border-top-color: #70b9ed;
      animation: spin 1s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { #dot { animation: none !important; } }
  </style>
</head>
<body data-state="waiting"><main>
  <div id="qr">${qrSvg(pairing.toString())}</div>
  <div id="result" hidden aria-hidden="true">
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3"
      stroke-linecap="round" stroke-linejoin="round">
      <path id="symbol" d="M12 24l8 8 16-17"/>
    </svg>
  </div>
  <section aria-live="polite" aria-atomic="true">
    <h1 id="heading">Pair with Airreload Go</h1>
    <ol id="steps">
      <li>Open Airreload Go on your phone.</li>
      <li>Tap Scan QR code.</li>
      <li>Scan here and confirm pairing.</li>
    </ol>
    <p id="message" hidden></p>
    <p id="status"><span id="dot" aria-hidden="true"></span><span id="label">Waiting for your phone</span></p>
  </section>
  <p class="hint" id="hint">Use the same trusted Wi-Fi network.<br>Keep the Airreload terminal running.</p>
  <noscript><p>Enable JavaScript to see live pairing status.</p></noscript>
</main>
<script>
  const el = (id) => document.getElementById(id);
  let previous = '';
  function render(state, message = '') {
    const key = state + message;
    if (previous === key) return;
    previous = key;
    const waiting = state === 'waiting';
    const titles = {waiting: 'Pair with Airreload Go', building: 'Phone paired',
      ready: 'App ready', error: 'Something went wrong', offline: 'Session unavailable'};
    const labels = {waiting: 'Waiting for your phone', building: 'Building your app',
      ready: 'Paired', error: 'Check your terminal', offline: 'Waiting for the CLI'};
    document.body.dataset.state = state;
    el('qr').hidden = !waiting;
    el('steps').hidden = !waiting;
    el('result').hidden = waiting;
    el('message').hidden = waiting;
    el('heading').textContent = titles[state];
    document.title = 'Airreload — ' + titles[state];
    el('message').textContent = message;
    el('label').textContent = labels[state];
    el('hint').hidden = !waiting;
    el('symbol').setAttribute('d', state === 'error' || state === 'offline'
      ? 'M24 12v16M24 35v1' : 'M12 24l8 8 16-17');
  }
  async function poll() {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 4000);
      let data;
      try {
        const response = await fetch(location.pathname + '/status',
          {cache: 'no-store', signal: controller.signal});
        if (!response.ok) throw new Error('Session unavailable');
        data = await response.json();
      } finally { clearTimeout(timeout); }
      if (!['waiting', 'building', 'ready', 'error'].includes(data.state)) {
        throw new Error('Unknown state');
      }
      render(data.state, data.message);
      if (data.state === 'error') return;
    } catch (_) {
      render('offline', 'Keep the terminal running. If this session has ended, run Airreload again and use the new QR page.');
    }
    setTimeout(poll, 1000);
  }
  poll();
</script>
</body>
</html>
''';
}

class PairingPageServer {
  PairingPageServer._(
    this._server,
    this.url,
    String html,
    Map<String, String> Function() readState,
  ) {
    _subscription = _server.listen((request) async {
      final response = request.response;
      response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Frame-Options', 'DENY');
      if (request.headers.value(HttpHeaders.hostHeader) != url.authority ||
          request.uri.hasQuery ||
          (request.uri.path != url.path &&
              request.uri.path != '${url.path}/status')) {
        response.statusCode = HttpStatus.notFound;
      } else if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == url.path) {
        response.headers.contentType = ContentType.html;
        response.write(html);
      } else {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(readState()));
      }
      await response.close().catchError((Object _) {});
    });
  }

  final HttpServer _server;
  final Uri url;
  late final StreamSubscription<HttpRequest> _subscription;

  static Future<PairingPageServer> start(
    Uri pairing,
    Map<String, String> Function() readState,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/pair/${randomToken().replaceAll('=', '')}',
    );
    return PairingPageServer._(server, url, qrPairingPage(pairing), readState);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

Future<bool> openQrPage(Uri page) async {
  if (Platform.environment.containsKey('SSH_CONNECTION') ||
      Platform.environment.containsKey('SSH_TTY')) {
    return false;
  }
  final String executable;
  final List<String> arguments;
  if (Platform.isMacOS) {
    executable = '/usr/bin/open';
    arguments = [page.toString()];
  } else if (Platform.isLinux) {
    executable = 'xdg-open';
    arguments = [page.toString()];
  } else if (Platform.isWindows) {
    executable = 'rundll32';
    arguments = ['url.dll,FileProtocolHandler', page.toString()];
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
