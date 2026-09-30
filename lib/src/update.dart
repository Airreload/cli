import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'workspace.dart';

const _rawSource = 'https://raw.githubusercontent.com/Airreload/installer';
const _marker = 'airreload-installer-v1';

typedef UpdateFetch = Future<String> Function(Uri uri);
typedef UpdateInstall = Future<int> Function(String script, String root);

class UpdateRelease {
  UpdateRelease(this.revision, this.manifest) {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw const FormatException('Invalid installer revision.');
    }
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(manifest)) {
      if (line.trim().isEmpty || line.startsWith('#')) continue;
      final split = line.indexOf('=');
      if (split < 1 || values.containsKey(line.substring(0, split))) {
        throw const FormatException('Invalid release manifest.');
      }
      values[line.substring(0, split)] = line.substring(split + 1);
    }
    final native = values['CLI_DISTRIBUTION'] == 'native';
    final validDistribution = native
        ? ['CLI_SHA256_MACOS_ARM64', 'CLI_SHA256_WINDOWS_X64'].every(
            (key) => RegExp(r'^[0-9a-f]{64}$').hasMatch(values[key] ?? ''),
          )
        : (values['CLI_DISTRIBUTION'] == null &&
              values['FLUTTER_REPOSITORY'] ==
                  'https://github.com/Airreload/flutter.git' &&
              RegExp(r'^[0-9a-f]{40}$')
                  .hasMatch(values['FLUTTER_COMMIT'] ?? '') &&
              RegExp(r'^[A-Za-z0-9._-]+$')
                  .hasMatch(values['FLUTTER_TAG'] ?? ''));
    if (values['CLI_REPOSITORY'] != 'https://github.com/Airreload/cli.git' ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(values['CLI_COMMIT'] ?? '') ||
        !validDistribution) {
      throw const FormatException('Invalid official release manifest.');
    }
    tag = values['CLI_TAG'] ?? '';
    if (!RegExp(r'^v[0-9A-Za-z.+-]+$').hasMatch(tag)) {
      throw const FormatException('Invalid CLI release tag.');
    }
    version = Version.parse(tag.substring(1));
  }

  final String revision;
  final String manifest;
  late final String tag;
  late final Version version;
  bool newerThan(String current) =>
      Version.parse(version.toString().split('+').first) >
      Version.parse(current.split('+').first);
  String changes(String current) =>
      'https://github.com/Airreload/cli/compare/v$current...$tag';
}

class UpdateManager {
  UpdateManager(
    this.workspace, {
    Logger? logger,
    this.fetch,
    UpdateInstall? install,
    this.currentVersion = cliVersion,
    bool? supported,
    bool? windows,
    DateTime Function()? now,
  }) : logger = logger ?? Logger(),
       _install = install ?? _runInstaller,
       windows = windows ?? Platform.isWindows,
       supported = supported ?? supportsAutomaticUpdates(),
       _now = now ?? DateTime.now;

  final Workspace workspace;
  final Logger logger;
  final UpdateFetch? fetch;
  final UpdateInstall _install;
  final String currentVersion;
  final bool supported;
  final bool windows;
  final DateTime Function() _now;
  File get _cache => File(p.join(workspace.state, 'update-check.json'));

  Future<bool> isManaged() async {
    if (await FileSystemEntity.type(workspace.root, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final marker = File(p.join(workspace.root, '.airreload-installer'));
    return await marker.exists() &&
        (await marker.readAsString()).trim() == _marker;
  }

  Future<UpdateRelease> latest({bool quick = false}) async {
    Future<String> get(Uri uri) =>
        fetch?.call(uri) ??
        _download(uri, timeout: Duration(seconds: quick ? 2 : 15));
    final body = jsonDecode(
      await get(
        Uri.parse(
          'https://api.github.com/repos/Airreload/installer/commits/main',
        ),
      ),
    ) as Map<String, dynamic>;
    final revision = body['sha'];
    if (revision is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw const FormatException('Invalid installer revision.');
    }
    return UpdateRelease(
      revision,
      await get(Uri.parse('$_rawSource/$revision/versions.env')),
    );
  }

  Future<int> update({bool checkOnly = false}) async {
    try {
      final release = await latest();
      if (!release.newerThan(currentVersion)) {
        logger.success(
          'Airreload is up to date (no newer published installer release).',
        );
        return 0;
      }
      logger.info(
        'A newer CLI release is available. Changes: ${release.changes(currentVersion)}',
      );
      if (!await isManaged() || !supported) {
        logger.info(
          'Automatic updates require an installer-owned macOS Apple Silicon or Windows x64 installation. '
          'For source installations, check out ${release.tag} in the CLI repository, '
          'run dart pub get, and rebuild the executable if you use one.',
        );
        return checkOnly ? 0 : 1;
      }
      if (checkOnly) {
        logger.info('Run airreload update to install this release here.');
        return 0;
      }
      await _ensureNoSessions();
      final temporary = await Directory.systemTemp.createTemp(
        'airreload-update-',
      );
      var handedOff = false;
      try {
        final scriptName = windows ? 'install.ps1' : 'install.sh';
        final script = File(p.join(temporary.path, scriptName));
        await script.writeAsString(
          await (fetch?.call(
                Uri.parse('$_rawSource/${release.revision}/$scriptName'),
              ) ??
              _download(
                Uri.parse('$_rawSource/${release.revision}/$scriptName'),
              )),
        );
        await File(p.join(temporary.path, 'versions.env'))
            .writeAsString(release.manifest);
        logger.info(
          'Updating ${workspace.root}; preserving pairing credentials and downloaded SDKs.',
        );
        final code = await _install(script.path, workspace.root);
        if (code != 0) {
          logger.err(
            'Update failed (installer exit $code). The installer rolls back failed replacements.',
          );
          return code;
        }
        if (windows) {
          handedOff = true;
          logger.info(
            'The updater has opened in a separate PowerShell window. '
            'This command will exit so Windows can replace airreload.exe. '
            'Wait for that window to confirm success, then run airreload version.',
          );
          return 0;
        }
        if (await _cache.exists()) await _cache.delete();
        logger.success('Updated Airreload to ${release.version}.');
        logger.info(
          'Run airreload version to verify. Re-run airreload run to build a fresh debug APK.',
        );
        return 0;
      } finally {
        if (!handedOff) await temporary.delete(recursive: true);
      }
    } on Object catch (error) {
      logger.err(
        'Could not update Airreload: $error. Retry with airreload update --check.',
      );
      return 1;
    }
  }

  // Notices are advisory: unavailable networks or corrupt caches must not break a run.
  Future<void> notifyIfAvailable() async {
    try {
      if (!await isManaged()) return;
      Map<String, dynamic>? cached;
      if (await _cache.exists()) {
        try {
          cached =
              jsonDecode(await _cache.readAsString()) as Map<String, dynamic>;
        } on Object {
          cached = null;
        }
      }
      final now = _now().toUtc();
      final checked = DateTime.tryParse(cached?['checkedAt']?.toString() ?? '');
      UpdateRelease? release;
      if (checked != null &&
          !checked.isAfter(now) &&
          now.difference(checked) < const Duration(days: 1)) {
        if (cached?['manifest'] is String && cached?['revision'] is String) {
          release = UpdateRelease(
            cached!['revision'] as String,
            cached['manifest'] as String,
          );
        }
      } else {
        try {
          release = await latest(quick: true);
        } on Object {
          // Cache failed attempts too so an offline user is not delayed on every run.
        }
        await Directory(workspace.state).create(recursive: true);
        await _cache.writeAsString(
          jsonEncode({
            'checkedAt': now.toIso8601String(),
            if (release != null) 'revision': release.revision,
            if (release != null) 'manifest': release.manifest,
          }),
        );
      }
      if (release != null && release.newerThan(currentVersion)) {
        logger.info(
          'Airreload update available: $currentVersion → ${release.version} '
          '(official installer release). Run airreload update --check to review changes, then airreload update to install.',
        );
      }
    } on Object {
      // Read-only commands and normal development remain usable offline.
    }
  }

  Future<void> _ensureNoSessions() async {
    final files = <File>[File(workspace.session)];
    final runs = Directory(p.join(workspace.state, 'runs'));
    if (await runs.exists()) {
      await for (final entry in runs.list(followLinks: false)) {
        if (entry is Directory) {
          files.add(File(p.join(entry.path, 'session.json')));
        }
      }
    }
    for (final file in files) {
      if (!await file.exists()) continue;
      final session =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final processId = session['pid'];
      if (processId is! int || processId <= 0) {
        throw StateError(
          'Cannot verify saved session in ${file.path}. Stop Airreload sessions before updating.',
        );
      }
      if (await _processIsRunning(processId)) {
        throw StateError(
          'Stop the running Airreload session (PID $processId) before updating.',
        );
      }
    }
  }
}

Future<String> _download(
  Uri uri, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'Airreload/$cliVersion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Release server returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      return utf8.decoder.bind(response).join();
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Future<int> _runInstaller(String script, String root) async {
  if (Platform.isWindows) {
    final encoded = encodePowerShell(windowsUpdateScript(script, root, pid));
    final result = await Process.run(_windowsPowerShell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$ErrorActionPreference = 'Stop'; "
          'Start-Process -FilePath ${_psQuote(_windowsPowerShell)} '
          '-WorkingDirectory ${_psQuote(Directory.systemTemp.path)} '
          "-ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', "
          "'-EncodedCommand', '$encoded') -WindowStyle Normal",
    ], workingDirectory: Directory.systemTemp.path);
    if (result.exitCode != 0) stderr.write(result.stderr);
    return result.exitCode;
  }
  final process = await Process.start(
    'bash',
    [script, '--replace', '--no-path', '--preserve-data'],
    workingDirectory: Directory.systemTemp.path,
    environment: {
      'AIRRELOAD_INSTALL_ROOT': root,
      'AIRRELOAD_NO_UPDATE_CHECK': '1',
    },
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

bool supportsAutomaticUpdates() =>
    (Platform.isMacOS && Platform.version.contains('arm64')) ||
    (Platform.isWindows &&
        Platform.version.contains('x64') &&
        Platform.environment['PROCESSOR_ARCHITECTURE'] != 'ARM64' &&
        Platform.environment['PROCESSOR_ARCHITEW6432'] != 'ARM64');

String get _windowsPowerShell => p.join(
  Platform.environment['SystemRoot'] ?? r'C:\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
);

Future<bool> _processIsRunning(int processId) async {
  final result = Platform.isWindows
      ? await Process.run(_windowsPowerShell, [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '\$process = Get-Process -Id $processId -ErrorAction SilentlyContinue; '
              'if (\$null -ne \$process) { exit 0 }; exit 1',
        ])
      : await Process.run('kill', ['-0', '$processId']);
  if (result.exitCode != 0 && result.exitCode != 1) {
    throw StateError('Could not check saved Airreload process $processId.');
  }
  return result.exitCode == 0;
}

String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

String encodePowerShell(String script) => base64Encode([
  for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
]);

// Windows locks the running native executable. The helper owns its temporary
// files after handoff and waits for the CLI to exit before replacing it.
String windowsUpdateScript(
  String script,
  String root,
  int parentPid, {
  bool pauseOnExit = true,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
\$failed = \$false
try {
  Write-Host 'Waiting for Airreload to exit...'
  \$owner = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
  if (\$null -ne \$owner -and -not \$owner.WaitForExit(120000)) {
    throw 'Airreload did not exit. Close it and retry the update.'
  }
  \$env:AIRRELOAD_INSTALL_ROOT = ${_psQuote(root)}
  \$env:AIRRELOAD_NO_UPDATE_CHECK = '1'
  & ${_psQuote(script)} -Replace -NoPath -PreserveData
  \$cache = Join-Path \$env:AIRRELOAD_INSTALL_ROOT 'cli\\.airreload\\update-check.json'
  if (Test-Path -LiteralPath \$cache) { Remove-Item -LiteralPath \$cache -Force }
  Write-Host 'Airreload update completed. Run airreload version in your terminal.'
} catch {
  \$failed = \$true
  Write-Host ("Airreload update failed: " + \$_.Exception.Message) -ForegroundColor Red
} finally {
  Remove-Item -LiteralPath ${_psQuote(p.dirname(script))} -Recurse -Force -ErrorAction SilentlyContinue
${pauseOnExit ? "  Read-Host 'Press Enter to close' | Out-Null\n" : ''}}
if (\$failed) { exit 1 }
''';
