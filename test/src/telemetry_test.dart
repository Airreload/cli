import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airreload/src/cli.dart';
import 'package:airreload/src/telemetry.dart';
import 'package:airreload/src/workspace.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

class LocalClient extends Fake implements HttpClient {
  LocalClient(this.server, this.destinations, this.redirects);
  final HttpServer server;
  final List<Uri> destinations;
  final List<HttpClientRequest> redirects;
  final client = HttpClient();
  bool closed = false;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> postUrl(Uri uri) async {
    destinations.add(uri);
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}${uri.path}'),
    );
    redirects.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
    client.close(force: force);
  }
}

void main() {
  late Directory directory;
  late Workspace workspace;
  late HttpServer server;
  late List<Map<String, dynamic>> events;
  late List<Uri> destinations;
  late List<HttpClientRequest> requests;
  late List<LocalClient> clients;
  late List<Telemetry> instances;
  var responseCode = 200;
  var hang = false;

  Telemetry create({Map<String, String> extra = const {}, Duration? timeout}) {
    final telemetry = Telemetry(
      workspace,
      environment: {
        'AIRRELOAD_POSTHOG_TOKEN': 'phc_synthetic_test',
        'AIRRELOAD_POSTHOG_REGION': 'eu',
        ...extra,
      },
      requestTimeout: timeout ?? const Duration(seconds: 1),
      clientFactory: () {
        final client = LocalClient(server, destinations, requests);
        clients.add(client);
        return client;
      },
    );
    instances.add(telemetry);
    return telemetry;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('airreload-telemetry-');
    workspace = Workspace(directory.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    events = [];
    destinations = [];
    requests = [];
    clients = [];
    instances = [];
    responseCode = 200;
    hang = false;
    server.listen((request) async {
      events.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      if (hang) return;
      request.response.statusCode = responseCode;
      if (responseCode == 302) {
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/redirect',
        );
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    for (final telemetry in instances) {
      await telemetry.close();
    }
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('default on, status and help create no state or network', () async {
    final telemetry = create();
    expect(telemetry.status, contains('enabled (default)'));
    expect(telemetry.status, contains('Collection: enabled'));
    await runCli([
      'telemetry',
      'status',
    ], Operations(workspace, telemetry: telemetry));
    await runCli([
      'telemetry',
      '--help',
    ], Operations(workspace, telemetry: create()));
    expect(clients, isEmpty);
    expect(Directory(workspace.state).existsSync(), isFalse);
  });

  test(
    'fresh installation automatically gets a stable ID and sends events',
    () async {
      final telemetry = create();
      expect(await telemetry.initialize(), isTrue);
      final original = telemetry.settingsFile.readAsStringSync();
      expect(await create().initialize(), isFalse);
      expect(telemetry.settingsFile.readAsStringSync(), original);
      telemetry.capture(TelemetryEvent.runStarted);
      await telemetry.close();
      expect(events.single['event'], 'cli_run_started');
      expect(
        (events.single['properties'] as Map)['distinct_id'],
        (jsonDecode(original) as Map)['installation_id'],
      );
    },
  );

  test(
    'saved opt-out survives later initialization and sends nothing',
    () async {
      await create().setEnabled(false);
      final telemetry = create();
      expect(await telemetry.initialize(), isFalse);
      expect(telemetry.enabled, isFalse);
      telemetry.capture(TelemetryEvent.runStarted);
      await telemetry.close();
      expect(clients, isEmpty);
    },
  );

  test(
    'fresh environment overrides prevent creating an ID or sending',
    () async {
      for (final extra in [
        {'AIRRELOAD_TELEMETRY_DISABLED': '1'},
        {'DO_NOT_TRACK': '1'},
        {'CI': 'true'},
        {'CI': '1'},
        {'AIRRELOAD_POSTHOG_TOKEN': ''},
      ]) {
        final telemetry = create(extra: extra);
        expect(await telemetry.initialize(), isFalse);
        telemetry.capture(TelemetryEvent.runStarted);
        await telemetry.close();
      }
      expect(clients, isEmpty);
      expect(Directory(workspace.state).existsSync(), isFalse);
    },
  );

  test(
    'simultaneous initialization and opt-out preserve the opt-out',
    () async {
      final first = create();
      final second = create();
      await Future.wait<void>([
        first.initialize().then((_) {}),
        second.setEnabled(false),
        create().initialize().then((_) {}),
      ]);
      expect(first.enabled, isFalse);
      expect(await first.initialize(), isFalse);
      first.capture(TelemetryEvent.runStarted);
      expect(clients, isEmpty);
    },
  );

  test('unwritable state initialization does not interrupt commands', () async {
    await File('${directory.path}/cli').writeAsString('blocks state directory');
    final telemetry = create();
    expect(await telemetry.initialize(), isFalse);
    telemetry.capture(TelemetryEvent.runStarted);
    expect(clients, isEmpty);
  });

  test('enable persists random identity; disable removes it; re-enabling rotates it', () async {
    final telemetry = create();
    expect(
      await runCli([
        'telemetry',
        'enable',
      ], Operations(workspace, telemetry: telemetry)),
      0,
    );
    final original =
        jsonDecode(telemetry.settingsFile.readAsStringSync()) as Map;
    expect(original['installation_id'], matches(r'^[a-f0-9]{32}$'));
    expect(create().enabled, isTrue);
    await create().setEnabled(true);
    expect(jsonDecode(telemetry.settingsFile.readAsStringSync()), original);
    expect(
      await runCli([
        'telemetry',
        'disable',
      ], Operations(workspace, telemetry: create())),
      0,
    );
    expect(telemetry.enabled, isFalse);
    expect(
      telemetry.settingsFile.readAsStringSync(),
      isNot(contains('installation_id')),
    );
    await create().setEnabled(true);
    expect(
      jsonDecode(telemetry.settingsFile.readAsStringSync()),
      isNot(original),
    );
    expect(clients, isEmpty);
  });

  test(
    'missing configuration, secret keys and invalid regions never send',
    () async {
      await create().setEnabled(true);
      for (final extra in [
        {'AIRRELOAD_POSTHOG_TOKEN': ''},
        {'AIRRELOAD_POSTHOG_TOKEN': 'phx_secret'},
        {'AIRRELOAD_POSTHOG_TOKEN': 'phs_secret'},
        {'AIRRELOAD_POSTHOG_REGION': 'https://evil.example'},
      ]) {
        final telemetry = create(extra: extra);
        expect(telemetry.configured, isFalse);
        telemetry.capture(TelemetryEvent.runStarted);
        await telemetry.close();
      }
      expect(clients, isEmpty);
    },
  );

  test(
    'environment and CI overrides take precedence over saved preferences',
    () async {
      await create().setEnabled(true);
      for (final extra in [
        {'AIRRELOAD_TELEMETRY_DISABLED': '1'},
        {'DO_NOT_TRACK': '1'},
        {'CI': 'true'},
        {'CI': '1'},
      ]) {
        final telemetry = create(extra: extra);
        telemetry.capture(TelemetryEvent.runStarted);
        expect(telemetry.status, contains('Collection: disabled'));
        await telemetry.close();
      }
      expect(clients, isEmpty);
    },
  );

  test(
    'malformed, unsupported and oversized preferences fail closed',
    () async {
      final telemetry = create();
      await telemetry.setEnabled(true);
      for (final value in [
        '{',
        '[]',
        '{"enabled":true}',
        '{"version":2,"enabled":true,"installation_id":"${'a' * 32}"}',
        'a' * 4097,
      ]) {
        await telemetry.settingsFile.writeAsString(value);
        expect(await telemetry.initialize(), isFalse);
        telemetry.capture(TelemetryEvent.runStarted);
        expect(telemetry.enabled, isFalse);
      }
      expect(clients, isEmpty);
    },
  );

  test(
    'payload is allowlisted and disables profiles and geolocation',
    () async {
      final telemetry = create();
      await telemetry.setEnabled(true);
      telemetry.capture(
        TelemetryEvent.runEnded,
        flutterVersion: '3.47.5',
        stage: RunStage.build,
        outcome: RunOutcome.failed,
        duration: const Duration(milliseconds: 123),
      );
      await telemetry.close();
      expect(events, hasLength(1));
      expect(
        destinations.single.toString(),
        'https://eu.i.posthog.com/i/v0/e/',
      );
      expect(requests.single.followRedirects, isFalse);
      final event = events.single;
      expect(
        event.keys,
        unorderedEquals(['token', 'event', 'timestamp', 'properties']),
      );
      expect(event['event'], 'cli_run_ended');
      final props = event['properties'] as Map<String, dynamic>;
      expect(
        props.keys,
        unorderedEquals([
          'distinct_id',
          'surface',
          'cli_version',
          'os',
          r'$process_person_profile',
          r'$geoip_disable',
          r'$ip',
          'flutter_version',
          'stage',
          'outcome',
          'duration_ms',
        ]),
      );
      expect(props[r'$process_person_profile'], false);
      expect(props[r'$geoip_disable'], true);
      expect(props[r'$ip'], isNull);
      expect(props['duration_ms'], 123);
      expect(jsonEncode(event), isNot(contains(directory.path)));
      expect(clients.every((c) => c.closed), isTrue);
    },
  );

  test('untrusted version values are omitted and US routing works', () async {
    final telemetry = create(extra: {'AIRRELOAD_POSTHOG_REGION': 'us'});
    await telemetry.setEnabled(true);
    telemetry.capture(
      TelemetryEvent.runStarted,
      flutterVersion: '/private/project?token=secret',
    );
    await telemetry.close();
    expect(destinations.single.host, 'us.i.posthog.com');
    expect(events.single['properties'], isNot(contains('flutter_version')));
  });

  test(
    'another process can disable collection before subsequent events',
    () async {
      final telemetry = create();
      await telemetry.setEnabled(true);
      await create().setEnabled(false);
      telemetry.capture(TelemetryEvent.runStarted);
      await telemetry.close();
      expect(clients, isEmpty);
    },
  );

  test(
    'timeouts bound network work and drop excess events without blocking',
    () async {
      hang = true;
      final telemetry = create(timeout: const Duration(milliseconds: 80));
      await telemetry.setEnabled(true);
      final clock = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        telemetry.capture(TelemetryEvent.runStarted);
      }
      expect(clients.length, lessThanOrEqualTo(4));
      await telemetry.close();
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
      expect(clients.every((c) => c.closed), isTrue);
    },
  );

  for (final code in [302, 429, 500]) {
    test(
      'HTTP $code is silently dropped without redirects or retries',
      () async {
        responseCode = code;
        final telemetry = create();
        await telemetry.setEnabled(true);
        telemetry.capture(TelemetryEvent.runStarted);
        await telemetry.close();
        expect(events, hasLength(1));
        expect(destinations, hasLength(1));
      },
    );
  }

  test(
    'workflow failure reports a fixed stage without error text or paths',
    () async {
      final telemetry = create();
      final operations = Operations(workspace, telemetry: telemetry);
      expect(
        await runCli([
          'run',
          '--project',
          '${directory.path}/secret-app',
        ], operations),
        1,
      );
      expect(events.map((e) => e['event']), [
        'cli_run_started',
        'cli_run_ended',
      ]);
      final props = events.last['properties'] as Map;
      expect(props['stage'], RunStage.setup.name);
      expect(props['outcome'], RunOutcome.failed.name);
      expect(jsonEncode(events), isNot(contains('secret-app')));
    },
  );
}
