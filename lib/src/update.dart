import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'workspace.dart';

const updateSource =
    'https://github.com/Airreload/installer/blob/main/versions.env';
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
    if (values['CLI_REPOSITORY'] != 'https://github.com/Airreload/cli.git' ||
        values['FLUTTER_REPOSITORY'] !=
            'https://github.com/Airreload/flutter.git' ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(values['CLI_COMMIT'] ?? '') ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(values['FLUTTER_COMMIT'] ?? '') ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(values['FLUTTER_TAG'] ?? '')) {
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
    DateTime Function()? now,
  }) : logger = logger ?? Logger(),
       _install = install ?? _runInstaller,
       supported =
           supported ??
           (Platform.isMacOS && Platform.version.contains('arm64')),
       _now = now ?? DateTime.now;

  final Workspace workspace;
  final Logger logger;
  final UpdateFetch? fetch;
  final UpdateInstall _install;
  final String currentVersion;
  final bool supported;
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
      logger.info('Installed: Airreload $currentVersion');
      logger.info('Available: Airreload ${release.version}');
      logger.info('Source: $updateSource');
      logger.info('Installation: ${workspace.root}');
      logger.info(
        'Scope: Airreload CLI and its bundled Flutter/Dart runtime. '
        'Project SDK downloads and pairing credentials are preserved; Airreload Go is updated separately.',
      );
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
          'Automatic updates require an installer-owned macOS Apple Silicon installation. '
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
      try {
        final script = File(p.join(temporary.path, 'install.sh'));
        await script.writeAsString(
          await (fetch?.call(
                Uri.parse('$_rawSource/${release.revision}/install.sh'),
              ) ??
              _download(
                Uri.parse('$_rawSource/${release.revision}/install.sh'),
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
        if (await _cache.exists()) await _cache.delete();
        logger.success('Updated Airreload to ${release.version}.');
        logger.info(
          'Run airreload version to verify. Re-run airreload run to build a fresh debug APK.',
        );
        return 0;
      } finally {
        await temporary.delete(recursive: true);
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
          '(official installer release). Run airreload update --check for changes and installation details.',
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
      final result = await Process.run('kill', ['-0', '$processId']);
      if (result.exitCode == 0) {
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
