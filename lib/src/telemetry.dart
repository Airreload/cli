import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'platform_support.dart';
import 'workspace.dart';

// Public collection token only. No account/secret API keys belong in the CLI.
const _projectToken = String.fromEnvironment(
  'AIRRELOAD_POSTHOG_TOKEN',
  defaultValue: 'phc_zSnDnDZpCrxj27TRpXksGrp6RPhyZyYMmXyYx8q9XxFP',
);
const _region = String.fromEnvironment(
  'AIRRELOAD_POSTHOG_REGION',
  defaultValue: 'us',
);

enum TelemetryEvent {
  integrationTest('cli_telemetry_test'),
  runStarted('cli_run_started'),
  phonePaired('cli_phone_paired'),
  buildSucceeded('cli_build_succeeded'),
  appConnected('cli_app_connected'),
  runEnded('cli_run_ended');

  const TelemetryEvent(this.eventName);
  final String eventName;
}

enum RunStage { setup, pairing, build, connection, attach }

enum RunOutcome { completed, cancelled, failed }

class Telemetry {
  Telemetry(
    this.workspace, {
    Map<String, String>? environment,
    HttpClient Function()? clientFactory,
    this.requestTimeout = const Duration(seconds: 1),
  }) : environment = Map.unmodifiable(environment ?? Platform.environment),
       _clientFactory = clientFactory ?? HttpClient.new;

  final Workspace workspace;
  final Map<String, String> environment;
  final HttpClient Function() _clientFactory;
  final Duration requestTimeout;
  final _pending = <Future<void>>{};
  final _clients = <HttpClient>{};
  var _closed = false;
  var _sent = 0;
  static final _writes = <String, Future<void>>{};

  File get settingsFile => File(p.join(workspace.state, 'telemetry.json'));
  String get _token => environment['AIRRELOAD_POSTHOG_TOKEN'] ?? _projectToken;
  String get region => environment['AIRRELOAD_POSTHOG_REGION'] ?? _region;
  bool get configured =>
      RegExp(r'^phc_[A-Za-z0-9_-]+$').hasMatch(_token) &&
      {'us', 'eu'}.contains(region);
  bool get overridden =>
      environment['AIRRELOAD_TELEMETRY_DISABLED'] == '1' ||
      environment['DO_NOT_TRACK'] == '1' ||
      environment['CI']?.toLowerCase() == 'true' ||
      environment['CI'] == '1';

  bool get _settingsMissing =>
      FileSystemEntity.typeSync(settingsFile.path, followLinks: false) ==
      FileSystemEntityType.notFound;

  // Invalid preferences fail closed. A missing preference uses the enabled
  // default; initialize() creates the ID before a run emits events.
  String? get _installationId {
    try {
      if (!settingsFile.existsSync() || settingsFile.lengthSync() > 4096) {
        return null;
      }
      final value = jsonDecode(settingsFile.readAsStringSync());
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['enabled'] != true) {
        return null;
      }
      final id = value['installation_id'];
      return id is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ? id : null;
    } catch (_) {
      return null;
    }
  }

  bool get enabled => _settingsMissing || _installationId != null;

  Future<bool> initialize() async {
    if (_closed || !configured || overridden) return false;
    var created = false;
    try {
      if (!_settingsMissing) return false;
      await _withSettingsLock(() async {
        // Recheck under the lock: never overwrite a concurrent opt-out.
        if (_closed || !_settingsMissing) return;
        await _writePreference(true);
        created = true;
      });
    } catch (_) {
      // A read-only installation must still be able to run without analytics.
    }
    return created;
  }

  Future<void> setEnabled(bool enabled) =>
      _withSettingsLock(() => _writePreference(enabled));

  Future<void> _withSettingsLock(Future<void> Function() action) async {
    final key = settingsFile.absolute.path;
    final previous = _writes[key];
    final completed = Completer<void>();
    _writes[key] = completed.future;
    try {
      await previous;
      await workspace.preparePrivateDirectory();
      final lock = await File('${settingsFile.path}.lock')
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        await action();
      } finally {
        await lock.close();
      }
    } finally {
      completed.complete();
      if (identical(_writes[key], completed.future)) _writes.remove(key);
    }
  }

  Future<void> _writePreference(bool enabled) async {
    final existing = _installationId;
    final temporary = await Directory(workspace.state).createTemp('telemetry-');
    try {
      await restrictAccess(temporary.path, directory: true);
      final file = File(p.join(temporary.path, 'settings.json'));
      final random = Random.secure();
      final id = enabled
          ? existing ??
                List.generate(
                  16,
                  (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
                ).join()
          : null;
      await file.writeAsString(
        jsonEncode({'version': 1, 'enabled': enabled, 'installation_id': ?id}),
        flush: true,
      );
      await restrictAccess(file.path, directory: false);
      await file.rename(settingsFile.path);
      if (!enabled) {
        for (final client in _clients.toList()) {
          client.close(force: true);
        }
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  String get status {
    final preference = _settingsMissing
        ? 'enabled (default)'
        : enabled
        ? 'enabled'
        : 'disabled';
    return 'Telemetry preference: $preference.\n'
        'Collection: ${enabled && configured && !overridden ? 'enabled' : 'disabled'}.\n'
        'PostHog: ${configured ? '$region region configured' : 'not configured (requires a public phc_ token and us/eu region)'}.\n'
        '${overridden ? 'Disabled by environment or CI.\n' : ''}'
        'Sends run milestones, outcomes, durations, CLI/Flutter versions, OS, '
        'and a random installation ID to PostHog.\n'
        'No source code, paths, command arguments, logs, or credentials.\n'
        'Disable: airreload telemetry disable';
  }

  // Typed fields deliberately prevent forwarding arbitrary logs or arguments.
  void capture(
    TelemetryEvent event, {
    String? flutterVersion,
    RunStage? stage,
    RunOutcome? outcome,
    Duration? duration,
  }) {
    try {
      if (_closed ||
          !configured ||
          overridden ||
          _pending.length >= 4 ||
          _sent >= 64) {
        return;
      }
      final id = _installationId;
      if (id == null) return;
      final payload = jsonEncode({
        'token': _token,
        'event': event.eventName,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'properties': {
          'distinct_id': id,
          'surface': 'cli',
          'cli_version': cliVersion,
          'os': Platform.operatingSystem,
          r'$process_person_profile': false,
          r'$geoip_disable': true,
          r'$ip': null,
          if (flutterVersion != null &&
              RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(flutterVersion))
            'flutter_version': flutterVersion,
          if (stage != null) 'stage': stage.name,
          if (outcome != null) 'outcome': outcome.name,
          if (duration != null)
            'duration_ms': duration.inMilliseconds.clamp(0, 604800000),
        },
      });
      _sent++;
      final request = _send(payload, id);
      _pending.add(request);
      unawaited(request.then((_) => _pending.remove(request)));
    } catch (_) {
      // Telemetry must never alter a command's behavior or expose diagnostics.
    }
  }

  Future<void> _send(String payload, String id) async {
    HttpClient? client;
    try {
      client = _clientFactory();
      _clients.add(client);
      client.connectionTimeout = requestTimeout;
      await (() async {
        final request = await client!.postUrl(
          Uri.https('$region.i.posthog.com', '/i/v0/e/'),
        );
        // Do not forward events to a redirect destination.
        request.followRedirects = false;
        if (_closed || overridden || _installationId != id) return;
        request.headers.contentType = ContentType.json;
        request.write(payload);
        final response = await request.close();
        await response.drain<void>();
      })().timeout(requestTimeout);
    } catch (_) {
      // Best effort: no retries, disk queue, or error text sent to PostHog.
    } finally {
      client?.close(force: true);
      _clients.remove(client);
    }
  }

  Future<void> close() async {
    // Only command shutdown waits, for at most 250 ms across all requests.
    try {
      await Future.wait(_pending.toList())
          .timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // Dropping events is preferable to delaying the CLI.
    } finally {
      _closed = true;
      for (final client in _clients.toList()) {
        client.close(force: true);
      }
    }
  }
}
