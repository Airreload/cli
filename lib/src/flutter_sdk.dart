import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'platform_support.dart';

class FlutterRelease {
  const FlutterRelease(this.version, this.dartVersion, this.commit);
  final String version;
  final String dartVersion;
  final String commit;
  String get tag => 'airreload-flutter-$version-v1-rc.1';
}

// Immutable testing releases. Physical-phone acceptance is recorded separately.
const flutterReleases = <FlutterRelease>[
  FlutterRelease(
    '3.47.5',
    '3.13.4',
    '1df5bcb36180331a0a696375d7d15403053be1c2',
  ),
  FlutterRelease(
    '3.44.9',
    '3.12.2',
    '16a405b682fb261646bd8e2cc2453c08fc90214f',
  ),
  FlutterRelease(
    '3.41.9',
    '3.11.5',
    '45650b965f55017ea97f94d2adc25102879b3f44',
  ),
  FlutterRelease(
    '3.38.10',
    '3.10.9',
    '89d0e1bd0b63a9c47f4e854d8f7b85386c1589b8',
  ),
];

FlutterRelease exactFlutterRelease(String version) {
  for (final release in flutterReleases) {
    if (release.version == version) return release;
  }
  throw StateError(
    'Airreload Flutter $version is unavailable. No other version was selected. '
    'Available versions: ${flutterReleases.map((r) => r.version).join(', ')}. '
    'Use --flutter-version with an exact available version.',
  );
}

Future<String?> fvmVersion(String project) async {
  var directory = Directory(p.absolute(project));
  while (true) {
    for (final name in ['.fvmrc', p.join('.fvm', 'fvm_config.json')]) {
      final file = File(p.join(directory.path, name));
      if (!await file.exists()) continue;
      try {
        final value = jsonDecode(await file.readAsString());
        final version = value is Map
            ? value[name == '.fvmrc' ? 'flutter' : 'flutterSdkVersion']
            : null;
        if (version is! String || version.trim().isEmpty) {
          throw const FormatException('Missing Flutter version');
        }
        return version.trim();
      } on FormatException {
        throw StateError('Invalid FVM configuration: ${file.path}.');
      }
    }
    if (directory.parent.path == directory.path) return null;
    directory = directory.parent;
  }
}

typedef SdkCommand = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

Map<String, dynamic> flutterVersionMetadata(String output) {
  // A fresh Flutter launcher can print SDK download/bootstrap progress before
  // the machine-readable version object, including curl's progress meter.
  final start = RegExp(r'^\s*\{', multiLine: true).firstMatch(output);
  if (start == null) {
    throw const FormatException('Flutter returned no version metadata');
  }
  final value = jsonDecode(output.substring(start.start));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid Flutter version metadata');
  }
  return value;
}

class FlutterSdkManager {
  FlutterSdkManager(this.root, this.logger, {SdkCommand? command})
    : command = command ?? runProcess;

  final String root;
  final Logger logger;
  final SdkCommand command;
  String get cache => p.join(root, 'sdks');

  Future<String?> _installedVersion(String project) async {
    // A configured IDE SDK takes precedence over the executable on PATH.
    final settings = File(p.join(project, '.vscode', 'settings.json'));
    String executable = Platform.isWindows ? 'flutter.bat' : 'flutter';
    if (await settings.exists()) {
      try {
        final document = jsonDecode(await settings.readAsString());
        final configured = document is Map
            ? document['dart.flutterSdkPath']
            : null;
        if (configured is String && !configured.contains(r'$')) {
          // The setting names an SDK directory, which need not be called flutter.
          executable = p.join(
            p.normalize(p.join(project, configured)),
            'bin',
            Platform.isWindows ? 'flutter.bat' : 'flutter',
          );
        }
      } on FormatException {
        // VS Code also accepts JSON with comments; use PATH in that case.
      }
    }
    try {
      final result = await command(executable, [
        '--version',
        '--machine',
      ], workingDirectory: project);
      if (result.exitCode != 0) return null;
      final document = flutterVersionMetadata(result.stdout.toString());
      final version = document['frameworkVersion'];
      return version is String ? version : null;
    } on ProcessException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<FlutterRelease> select(String project, {String? requested}) async {
    if (requested != null) {
      final release = exactFlutterRelease(requested);
      logger.info('Using requested Flutter version: ${release.version}');
      return release;
    }
    logger.info('Checking project Flutter version…');
    var detected = await fvmVersion(project);
    if (detected != null) {
      logger.success('✓ FVM configuration found: Flutter $detected');
    } else {
      logger.info('No FVM configuration found');
      logger.info('Checking installed Flutter…');
      detected = await _installedVersion(project);
      if (detected != null) logger.success('✓ Detected Flutter $detected');
    }
    for (final release in flutterReleases) {
      if (release.version == detected) return release;
    }
    final spec = loadYaml(
      await File(p.join(project, 'pubspec.yaml')).readAsString(),
    );
    final environment = spec is YamlMap ? spec['environment'] : null;
    bool allowed(FlutterRelease release) {
      if (environment is! YamlMap) return true;
      for (final entry in {
        'flutter': release.version,
        'sdk': release.dartVersion,
      }.entries) {
        final constraint = environment[entry.key];
        if (constraint is String &&
            !VersionConstraint.parse(constraint)
                .allows(Version.parse(entry.value))) {
          return false;
        }
      }
      return true;
    }

    final choices = flutterReleases.where(allowed).toList();
    if (choices.isEmpty) {
      throw StateError(
        'No available Airreload Flutter version satisfies this project’s SDK constraints.',
      );
    }
    Version? detectedVersion;
    try {
      detectedVersion = Version.parse(detected ?? '');
    } on FormatException {
      // FVM also accepts channel names and commit revisions.
    }
    final proposed = detectedVersion == null
        ? choices.first
        : choices.reduce((closest, candidate) {
            final target = detectedVersion!;
            final closestVersion = Version.parse(closest.version);
            final candidateVersion = Version.parse(candidate.version);
            final closestDistance = (
              (closestVersion.major - target.major).abs(),
              (closestVersion.minor - target.minor).abs(),
              (closestVersion.patch - target.patch).abs(),
            );
            final candidateDistance = (
              (candidateVersion.major - target.major).abs(),
              (candidateVersion.minor - target.minor).abs(),
              (candidateVersion.patch - target.patch).abs(),
            );
            if (candidateDistance.$1 != closestDistance.$1) {
              return candidateDistance.$1 < closestDistance.$1
                  ? candidate
                  : closest;
            }
            if (candidateDistance.$2 != closestDistance.$2) {
              return candidateDistance.$2 < closestDistance.$2
                  ? candidate
                  : closest;
            }
            if (candidateDistance.$3 != closestDistance.$3) {
              return candidateDistance.$3 < closestDistance.$3
                  ? candidate
                  : closest;
            }
            return candidateVersion > closestVersion ? candidate : closest;
          });
    logger.info(
      detected == null
          ? 'No Flutter installation detected.'
          : 'Airreload does not have an exact release for Flutter $detected.',
    );
    logger.info(
      detectedVersion == null
          ? 'Picking Flutter ${proposed.version}, the latest compatible Airreload version.'
          : 'Picking Flutter ${proposed.version}, the closest compatible Airreload version.',
    );
    return proposed;
  }

  Future<ProcessResult> _checked(
    String executable,
    List<String> arguments, {
    String? directory,
    String? progressMessage,
  }) async {
    final progress =
        progressMessage != null &&
            stdout.hasTerminal &&
            stdout.supportsAnsiEscapes
        ? logger.progress(progressMessage)
        : null;
    if (progressMessage != null && progress == null) {
      logger.info('$progressMessage…');
    }
    try {
      final result = await command(
        executable,
        arguments,
        workingDirectory: directory,
      );
      if (result.exitCode != 0) {
        throw StateError(
          '$executable ${arguments.first} failed (exit ${result.exitCode}):\n${result.stderr}',
        );
      }
      progress?.complete();
      return result;
    } catch (_) {
      progress?.fail();
      rethrow;
    }
  }

  Future<void> _verify(String directory, FlutterRelease release) async {
    final head = await _checked('git', ['-C', directory, 'rev-parse', 'HEAD']);
    if (head.stdout.toString().trim() != release.commit) {
      throw StateError(
        'Flutter ${release.version} does not match its published Airreload commit.',
      );
    }
    final dirty = await _checked('git', [
      '-C',
      directory,
      'status',
      '--porcelain',
      '--untracked-files=no',
    ]);
    if (dirty.stdout.toString().trim().isNotEmpty) {
      throw StateError(
        'Airreload Flutter ${release.version} has modified SDK files: $directory',
      );
    }
  }

  Future<String> install(FlutterRelease release) async {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(release.commit)) {
      throw StateError(
        'Flutter ${release.version} has no published Airreload revision yet.',
      );
    }
    final bundled = p.join(root, 'flutter');
    final bundledVersion = File(
      p.join(bundled, 'bin', 'internal', 'airreload.version'),
    );
    if (await bundledVersion.exists() &&
        (await bundledVersion.readAsString()).trim() == release.version &&
        await File(
          p.join(
            bundled,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dart.exe' : 'dart',
          ),
        ).exists()) {
      await _verify(bundled, release);
      return bundled;
    }
    await Directory(cache).create(recursive: true);
    final name = '${release.version}-${release.commit.substring(0, 12)}';
    final destination = p.join(cache, name);
    final lock = await File(p.join(cache, '$name.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final ready = File(p.join(destination, '.airreload-ready'));
      if (await ready.exists()) {
        await _verify(destination, release);
        if (await ready.readAsString() == release.commit &&
            await File(
              p.join(
                destination,
                'bin',
                'cache',
                'dart-sdk',
                'bin',
                Platform.isWindows ? 'dart.exe' : 'dart',
              ),
            ).exists()) {
          return destination;
        }
        throw StateError(
          'Incomplete SDK at $destination. Remove that cache entry and retry.',
        );
      }
      if (await Directory(destination).exists()) {
        throw StateError(
          'Incomplete SDK at $destination. Remove that cache entry and retry.',
        );
      }
      final staging = await Directory(cache).createTemp('.install-$name-');
      final sdk = p.join(staging.path, 'flutter');
      try {
        await _checked('git', [
          'clone',
          '--quiet',
          '--depth',
          '4',
          '--single-branch',
          '--branch',
          release.tag,
          'https://github.com/Airreload/flutter.git',
          sdk,
        ], progressMessage: 'Downloading Flutter ${release.version}');
        await _verify(sdk, release);
        final executable = p.join(
          sdk,
          'bin',
          Platform.isWindows ? 'flutter.bat' : 'flutter',
        );
        final version = await _checked(executable, [
          '--version',
          '--machine',
        ], progressMessage: 'Preparing Flutter ${release.version} tools');
        final metadata = flutterVersionMetadata(version.stdout.toString());
        if (metadata['frameworkRevision'] != release.commit ||
            metadata['frameworkVersion'] != release.version) {
          throw StateError(
            'Flutter ${release.version} bootstrap returned an unexpected SDK identity.',
          );
        }
        final help = await _checked(executable, ['attach', '--help']);
        if (!help.stdout.toString().contains('--airreload-target-platform')) {
          throw StateError(
            'Flutter ${release.version} is missing Airreload attach support.',
          );
        }
        await File(p.join(sdk, '.airreload-ready'))
            .writeAsString(release.commit, flush: true);
        await Directory(sdk).rename(destination);
        logger.success('✓ Flutter ${release.version} ready');
        return destination;
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    } finally {
      await lock.close();
    }
  }
}
