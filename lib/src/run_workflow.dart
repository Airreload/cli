import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

import 'instrumentation.dart';
import 'flutter_sdk.dart';
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
    this.flutterVersion,
  });
  final String project;
  final String target;
  final String? host;
  final String? flavor;
  final List<String> defines;
  final List<String> defineFiles;
  final int waitSeconds;
  final String? flutterVersion;

  List<String> get dartArguments => [
    for (final value in defines) '--dart-define=$value',
    for (final file in defineFiles)
      '--dart-define-from-file=${p.normalize(p.join(p.absolute(project), file))}',
  ];
}

class _Cancelled implements Exception {}

/// Flutter target preference when a device reports more than one ABI.  Prefer
/// 64-bit ARM, then 32-bit ARM, then 64-bit x86. Flutter does not support an
/// x86-only APK target, so an x86-only phone is reported as incompatible.
String? flutterAndroidTargetForAbis(Iterable<String> abis) {
  final supported = abis.map((abi) => abi.toLowerCase()).toSet();
  if (supported.contains('arm64-v8a')) return 'android-arm64';
  if (supported.contains('armeabi-v7a')) return 'android-arm';
  if (supported.contains('x86_64')) return 'android-x64';
  return null;
}

class RunWorkflow {
  RunWorkflow(this.workspace, {Logger? logger}) : logger = logger ?? Logger();
  final Workspace workspace;
  final Logger logger;
  late final Workspace _sdk;
  final _cancelled = Completer<void>();
  Process? _process;

  Future<ProcessResult> _sdkCommand(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (_cancelled.isCompleted) throw _Cancelled();
    final child = await startProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    _process = child;
    if (_cancelled.isCompleted) stopProcess(child);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    final code = await child.exitCode;
    final result = ProcessResult(child.pid, code, await output, await errors);
    _process = null;
    if (_cancelled.isCompleted) throw _Cancelled();
    return result;
  }

  Future<int> _command(List<String> arguments, String directory) async {
    if (_cancelled.isCompleted) throw _Cancelled();
    final child = await startProcess(
      _sdk.flutter,
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

  Future<T> _waitWithProgress<T>(
    String message,
    String completed,
    Future<T> Function() action,
  ) async {
    final progress = stdout.hasTerminal && stdout.supportsAnsiEscapes
        ? logger.progress(message)
        : null;
    if (progress == null) logger.info('$message…');
    try {
      final result = await _untilCancelled(action());
      if (progress != null) {
        progress.complete(completed);
      } else {
        logger.success('✓ $completed');
      }
      return result;
    } on _Cancelled {
      progress?.cancel();
      rethrow;
    } catch (_) {
      progress?.fail();
      rethrow;
    }
  }

  Future<int> run(RunOptions options) async {
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    SessionHost? host;
    ApkServer? download;
    PairingServer? pairing;
    PairingPageServer? pairingPage;
    subscriptions.addAll(
      watchTermination(() {
        if (!_cancelled.isCompleted) _cancelled.complete();
        final process = _process;
        if (process != null) stopProcess(process);
      }),
    );
    try {
      final source = p.normalize(p.absolute(options.project));
      if (!await File(p.join(source, 'pubspec.yaml')).exists() ||
          !await Directory(p.join(source, 'android')).exists()) {
        throw StateError('Run from an existing Flutter Android app directory.');
      }
      final manager = FlutterSdkManager(
        workspace.root,
        logger,
        command: _sdkCommand,
      );
      final release = await manager.select(
        source,
        requested: options.flutterVersion,
      );
      logger.success(
        '✓ Airreload supports Flutter ${release.version} (preview)',
      );
      _sdk = Workspace(workspace.root, sdkRoot: await manager.install(release));
      if (_cancelled.isCompleted) throw _Cancelled();
      final address = await selectComputerAddress(options.host);
      await workspace.preparePrivateDirectory();
      final runs = await Directory(p.join(workspace.state, 'runs'))
          .create(recursive: true);
      final directory = await runs.createTemp('run-');
      final session = SessionWorkspace(workspace.root, directory.path);
      host = await SessionHost.start(session);
      pairing = await PairingServer.start();
      final prepared = await PreparedProject.create(
        source: source,
        destination: p.join(directory.path, 'project'),
        target: options.target,
        sdk: _sdk,
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
        'flutterVersion': release.version,
        'flutterCommit': release.commit,
        'flutterSdk': _sdk.sdkRoot,
      });
      final pairingUrl = pairing.url(address);
      final activePairing = pairing;
      pairingPage = await PairingPageServer.start(
        pairingUrl,
        () => activePairing.pageState,
      );
      final openedQrPage = await openQrPage(pairingPage.url);
      logger.info(
        openedQrPage
            ? '\nScan the pairing QR with Airreload Go, then confirm pairing on your phone.'
            : '\nOpen the pairing QR page below, scan it with Airreload Go, then confirm pairing on your phone.',
      );
      logger.info('QR page: ${pairingPage.url}');
      if (stdout.hasTerminal && stdout.supportsAnsiEscapes) {
        final qr = terminalQr(pairingUrl.toString());
        final width = qr
            .split('\n')
            .first
            .replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '')
            .length;
        if (stdout.terminalColumns > width) {
          logger.info('Terminal QR (if needed):');
          stdout.write(qr);
        }
      }
      final abis = await _waitWithProgress(
        'Waiting for Airreload Go to pair',
        'Phone paired',
        () => pairing!.waitForPhone().timeout(
          Duration(seconds: options.waitSeconds),
          onTimeout: () => throw StateError(
            'No phone paired. Scan the QR with Airreload Go, confirm pairing, and check that both devices are on the same trusted network.',
          ),
        ),
      );
      final targetPlatform = flutterAndroidTargetForAbis(abis);
      if (targetPlatform == null) {
        const message =
            'This phone reports no Flutter-supported ABI. Airreload supports arm64-v8a, armeabi-v7a, and x86_64; x86-only devices are not supported.';
        pairing.fail(message);
        await _untilCancelled(Future<void>.delayed(const Duration(seconds: 3)));
        throw StateError(message);
      }
      logger.info('Building your app for $targetPlatform…');
      final build = await _command([
        'build',
        'apk',
        '--debug',
        '--target-platform',
        targetPlatform,
        '--android-skip-build-dependency-validation',
        '--target=${prepared.target}',
        if (options.flavor != null) '--flavor=${options.flavor}',
        ...options.dartArguments,
      ], prepared.directory);
      if (build != 0) {
        const prefix = 'Debug APK build failed';
        pairing.fail('$prefix. See the Flutter build output on your computer.');
        await _untilCancelled(Future<void>.delayed(const Duration(seconds: 3)));
        throw StateError(
          '$prefix (exit $build). See the Flutter build output above.',
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
      pairing.publishDownload(download.url(address));
      logger.success('✓ App built');
      logger.info(
        'Airreload Go will download your app automatically. Approve Android\'s install prompt, then open your app.',
      );
      logger.info('Authorized download endpoint: $url');
      logger.info('APK: ${apk.path}');
      logger.info('Keep this terminal open.');
      var failures = 0;
      while (true) {
        final uri = await _waitWithProgress(
          'Waiting for your app to connect',
          'App connected',
          () => host!.waitForReadyApp().timeout(
            Duration(seconds: options.waitSeconds),
            onTimeout: () => throw StateError(
              'The app\'s VM service did not become reachable. Check that the phone can reach $address, then install and open this session\'s APK. If the wrong network interface was selected, rerun with --host.',
            ),
          ),
        );
        logger.info(
          'Starting Flutter attach; press r for hot reload, '
          'R for hot restart, d to detach, or q to quit. DevTools stays on this computer.',
        );
        final connectionGeneration = host.connectionGeneration;
        final code = await _command([
          ...attachArguments(
            uri.toString(),
            prepared.target,
            targetPlatform: targetPlatform,
          ),
          ...options.dartArguments,
        ], prepared.directory);
        if (shouldFinishAttach(
          code,
          stillConnected: host.debugUri != null,
          sameConnection: host.connectionGeneration == connectionGeneration,
        )) {
          return 0;
        }
        logger.warn(
          attachEndedMessage(
            code,
            stillConnected: host.debugUri != null,
            sameConnection: host.connectionGeneration == connectionGeneration,
          ),
        );
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
        await _untilCancelled(Future<void>.delayed(const Duration(seconds: 2)));
      }
    } on _Cancelled {
      return 130;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      try {
        try {
          await pairingPage?.close();
        } finally {
          await download?.close();
        }
      } finally {
        try {
          await pairing?.close();
        } finally {
          await host?.close();
        }
      }
      logger.info(
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

String attachEndedMessage(
  int exitCode, {
  required bool stillConnected,
  required bool sameConnection,
}) {
  if (!stillConnected || !sameConnection) {
    return 'Lost the app connection. Waiting for the phone to reconnect so '
        'reload, restart, and DevTools can resume (Ctrl-C stops the session).';
  }
  if (exitCode != 0) {
    return 'Flutter attach ended (exit $exitCode). If a hot restart was in '
        'progress, Airreload will reconnect automatically (Ctrl-C stops the session).';
  }
  return 'Connection ended. Waiting for the app to reconnect (Ctrl-C stops the session).';
}
