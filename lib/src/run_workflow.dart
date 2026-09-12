import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

import 'instrumentation.dart';
import 'platform_support.dart';
import 'qr_display.dart';
import 'session_host.dart';
import 'workspace.dart';

String terminalQr(String data) {
  final image = QrImage(QrCode(payload: QrPayload.fromString(data)));
  const border = 4;
  final size = image.moduleCount + border * 2;
  bool dark(int y, int x) =>
      y >= border &&
      x >= border &&
      y < size - border &&
      x < size - border &&
      image.isDark(y - border, x - border);
  final result = StringBuffer();
  for (var y = 0; y < size; y += 2) {
    result.write('\x1b[30;47m');
    for (var x = 0; x < size; x++) {
      final top = dark(y, x);
      final bottom = dark(y + 1, x);
      result.write(top ? (bottom ? '█' : '▀') : (bottom ? '▄' : ' '));
    }
    result.writeln('\x1b[0m');
  }
  return result.toString();
}

Future<String> selectComputerAddress(String? override) async {
  if (override != null) {
    final ip = InternetAddress.tryParse(override);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.isLoopback ||
        ip.address == '0.0.0.0') {
      throw StateError(
        '--host must be a LAN IPv4 address reachable by the phone.',
      );
    }
    return ip.address;
  }
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  String? preferred;
  try {
    if (Platform.isMacOS) {
      final route = await Process.run('/sbin/route', ['-n', 'get', 'default']);
      preferred = RegExp(r'interface:\s*(\S+)')
          .firstMatch(route.stdout.toString())
          ?.group(1);
    } else if (Platform.isLinux) {
      final route = await Process.run('ip', ['-4', 'route', 'get', '1.1.1.1']);
      preferred = RegExp(r'\bdev\s+(\S+)')
          .firstMatch(route.stdout.toString())
          ?.group(1);
    }
  } on ProcessException {
    /* Fall back to active interface enumeration. */
  }
  final candidates =
      [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.isLoopback && !address.address.startsWith('169.254.'))
              (interface.name, address.address),
      ]..sort(
        (a, b) => networkAddressRank(
          a.$1,
          a.$2,
          preferred: preferred,
        ).compareTo(networkAddressRank(b.$1, b.$2, preferred: preferred)),
      );
  for (final candidate in candidates) {
    if (!isVirtualInterface(candidate.$1)) return candidate.$2;
  }
  throw StateError(
    'No usable LAN IPv4 address found. Connect to Wi-Fi or use --host <computer-lan-ip>.',
  );
}

bool isVirtualInterface(String name) => RegExp(
  r'(^lo$|loopback|utun|\btun\b|docker|veth|virtual|vmware|vbox|hyper-v|vethernet|bluetooth)',
  caseSensitive: false,
).hasMatch(name);

int networkAddressRank(
  String interfaceName,
  String address, {
  String? preferred,
}) {
  if (isVirtualInterface(interfaceName)) return 4;
  if (interfaceName == preferred) return 0;
  if (RegExp(
    r'(^en\d|^eth|^wl|wlan|wi-?fi|wireless|ethernet)',
    caseSensitive: false,
  ).hasMatch(interfaceName)) {
    return 1;
  }
  if (RegExp(r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
      .hasMatch(address)) {
    return 2;
  }
  return 3;
}

class RunOptions {
  RunOptions({
    required this.project,
    this.target = 'lib/main.dart',
    this.host,
    this.flavor,
    this.defines = const [],
    this.defineFiles = const [],
    this.waitSeconds = 600,
  });
  final String project;
  final String target;
  final String? host;
  final String? flavor;
  final List<String> defines;
  final List<String> defineFiles;
  final int waitSeconds;

  List<String> get dartArguments => [
    for (final value in defines) '--dart-define=$value',
    for (final file in defineFiles)
      '--dart-define-from-file=${p.normalize(p.join(p.absolute(project), file))}',
  ];
}

class _Cancelled implements Exception {}

class RunWorkflow {
  RunWorkflow(this.workspace);
  final Workspace workspace;
  final _cancelled = Completer<void>();
  Process? _process;

  Future<int> _command(List<String> arguments, String directory) async {
    if (_cancelled.isCompleted) throw _Cancelled();
    final child = await startProcess(
      workspace.flutter,
      arguments,
      workingDirectory: directory,
      mode: ProcessStartMode.inheritStdio,
    );
    _process = child;
    if (_cancelled.isCompleted) stopProcess(child);
    final code = await child.exitCode;
    _process = null;
    if (_cancelled.isCompleted) throw _Cancelled();
    return code;
  }

  Future<T> _untilCancelled<T>(Future<T> future) => Future.any<T>([
    future,
    _cancelled.future.then<T>((_) => throw _Cancelled()),
  ]);

  Future<int> run(RunOptions options) async {
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    SessionHost? host;
    ApkServer? download;
    subscriptions.addAll(
      watchTermination(() {
        if (!_cancelled.isCompleted) _cancelled.complete();
        final process = _process;
        if (process != null) stopProcess(process);
      }),
    );
    try {
      final address = await selectComputerAddress(options.host);
      final source = p.normalize(p.absolute(options.project));
      if (!await File(p.join(source, 'pubspec.yaml')).exists() ||
          !await Directory(p.join(source, 'android')).exists()) {
        throw StateError('Run from an existing Flutter Android app directory.');
      }
      await workspace.preparePrivateDirectory();
      final runs = await Directory(p.join(workspace.state, 'runs'))
          .create(recursive: true);
      final directory = await runs.createTemp('run-');
      final session = SessionWorkspace(workspace.root, directory.path);
      host = await SessionHost.start(session);
      stdout.writeln(
        'Preparing your app for this session ($address). Existing hosts are unchanged.',
      );
      final prepared = await PreparedProject.create(
        source: source,
        destination: p.join(directory.path, 'project'),
        target: options.target,
        sdk: workspace,
        host: address,
        port: host.server.port,
        token: host.token,
        certificate: await File(session.certificate).readAsString(),
      );
      await session.writeSession({
        'port': host.server.port,
        'proxyPort': host.proxy.port,
        'token': host.token,
        'pid': pid,
        'project': prepared.directory,
        'source': source,
        'target': prepared.target,
        'host': address,
      });
      stdout.writeln(
        'Building an ARM64 debug APK. Your app source and release configuration are unchanged.',
      );
      final build = await _command([
        'build',
        'apk',
        '--debug',
        '--target-platform',
        'android-arm64',
        '--target=${prepared.target}',
        if (options.flavor != null) '--flavor=${options.flavor}',
        ...options.dartArguments,
      ], prepared.directory);
      if (build != 0) {
        throw StateError(
          'Debug APK build failed (exit $build). See the Flutter build output above.',
        );
      }
      final apk = File(
        p.join(
          prepared.directory,
          'build',
          'app',
          'outputs',
          'flutter-apk',
          options.flavor == null
              ? 'app-debug.apk'
              : 'app-${options.flavor!.toLowerCase()}-debug.apk',
        ),
      );
      download = await ApkServer.start(apk);
      final url = download.url(address).toString();
      final qrPage = File(p.join(directory.path, 'install.html'));
      await qrPage.writeAsString(qrDownloadPage(download.url(address)));
      final openedQrPage = await openQrPage(qrPage);
      stdout.writeln(
        openedQrPage
            ? '\nScan the QR in your browser with your Android phone, install the APK, then open your app.'
            : '\nOpen the QR page below on this computer, scan it with your Android phone, then install and open the app.',
      );
      stdout.writeln('QR page: ${qrPage.absolute.uri}');
      if (stdout.hasTerminal && stdout.supportsAnsiEscapes) {
        final qr = terminalQr(url);
        final width = qr
            .split('\n')
            .first
            .replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '')
            .length;
        if (stdout.terminalColumns > width) {
          stdout.writeln('Terminal QR (if needed):');
          stdout.write(qr);
        }
      }
      stdout.writeln('Download: $url');
      stdout.writeln('APK: ${apk.path}');
      stdout.writeln(
        'Keep this terminal open. Waiting for the app to connect…',
      );
      var failures = 0;
      while (true) {
        final uri = await _untilCancelled(
          host.waitForApp().timeout(
            Duration(seconds: options.waitSeconds),
            onTimeout: () => throw StateError(
              'No app connected. Check that the phone can reach $address, then install and open this session\'s APK. If the wrong network interface was selected, rerun with --host.',
            ),
          ),
        );
        stdout.writeln(
          'App connected. Starting Flutter attach; press r for hot reload, d to detach, or q to quit.',
        );
        final connectionGeneration = host.connectionGeneration;
        final code = await _command([
          ...attachArguments(uri.toString(), prepared.target),
          ...options.dartArguments,
        ], prepared.directory);
        if (shouldFinishAttach(
          code,
          stillConnected: host.debugUri != null,
          sameConnection: host.connectionGeneration == connectionGeneration,
        )) {
          return 0;
        }
        if (code != 0 &&
            host.debugUri == uri &&
            host.connectionGeneration == connectionGeneration) {
          if (++failures >= 2) {
            throw StateError(
              'Flutter attach failed (exit $code). Fix the error above, then run again.',
            );
          }
        } else {
          failures = 0;
        }
        stdout.writeln(
          'Connection ended. Waiting for the app to reconnect (Ctrl-C stops the session).',
        );
        await _untilCancelled(Future<void>.delayed(const Duration(seconds: 2)));
      }
    } on _Cancelled {
      return 130;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      try {
        await download?.close();
      } finally {
        await host?.close();
      }
      stdout.writeln(
        'Airreload session stopped. Its download and control endpoints are closed.',
      );
    }
  }
}

bool shouldFinishAttach(
  int exitCode, {
  required bool stillConnected,
  required bool sameConnection,
}) => exitCode == 0 && stillConnected && sameConnection;
