import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/io.dart';

import 'host.dart';
import 'run_workflow.dart';
import 'workspace.dart';

class Operations {
  Operations(this.workspace);
  final Workspace workspace;

  Future<int> runApp(RunOptions options) => RunWorkflow(workspace).run(options);

  Future<Map<String, dynamic>> session() => workspace.activeSession();
  Future<void> host(int port) => runHost(workspace, port);
  Future<int> attach(String project, List<String> arguments) async {
    final child = await Process.start(
      workspace.flutter,
      arguments,
      workingDirectory: project,
      mode: ProcessStartMode.inheritStdio,
    );
    return child.exitCode;
  }

  Future<int> doctor() async {
    var failed = false;
    void report(bool ok, String message) {
      stdout.writeln('${ok ? 'OK' : 'FAIL'}  $message');
      failed |= !ok;
    }

    report(
      Platform.isMacOS || Platform.isLinux,
      'Local host supports macOS/Linux.',
    );
    for (final tool in ['git', 'openssl']) {
      try {
        final result = await Process.run(tool, [
          tool == 'git' ? '--version' : 'version',
        ]);
        report(result.exitCode == 0, '$tool available');
      } on ProcessException {
        report(false, '$tool missing');
      }
    }
    final sdkExists = await File(workspace.flutter).exists();
    report(sdkExists, 'Flutter SDK: ${workspace.flutter}');
    if (sdkExists) {
      final head = await Process.run('git', [
        '-C',
        '${workspace.root}/flutter',
        'rev-parse',
        'HEAD',
      ]);
      report(
        head.exitCode == 0 && head.stdout.toString().trim() == sdkCommit,
        'Expected patched Flutter 3.47.2 base, commit $sdkCommit',
      );
      final help = await Process.run(workspace.flutter, ['attach', '--help']);
      report(
        help.exitCode == 0 && help.stdout.toString().contains('--airreload'),
        'Patched attach --airreload available',
      );
    }
    stdout.writeln('Host was not started; no phone connection attempted.');
    stdout.writeln(
      'Run airreload run from a Flutter Android app; Airreload generates the debug integration.',
    );
    return failed ? ExitCode.unavailable.code : ExitCode.success.code;
  }
}

class AirreloadRunner extends CommandRunner<int> {
  AirreloadRunner(this.operations)
    : super(
        'airreload',
        'Build, hot reload, and hot restart a Flutter Android app over your local network.\n'
            'Run airreload run from a standalone app with a top-level main function under lib/.\n'
            'Pub workspaces and add-to-app modules are not supported.',
      ) {
    final run = ActionCommand(
      'run',
      'Build an ARM64 debug APK, show its QR code, and attach for hot reload, hot restart, and DevTools.\nUse r to hot reload and R to hot restart Dart changes under lib/. Re-run after changing assets, dependencies, or native code. External Gradle file references are not rewritten.',
      (args) {
        final wait = int.tryParse(args['wait-timeout'] as String);
        if (wait == null || wait < 1) {
          throw UsageException(
            '--wait-timeout must be a positive number of seconds.',
            usage,
          );
        }
        return operations.runApp(
          RunOptions(
            project: args['project'] as String? ?? Directory.current.path,
            target: args['target'] as String,
            host: args['host'] as String?,
            flavor: args['flavor'] as String?,
            defines: args['dart-define'] as List<String>,
            defineFiles: args['dart-define-from-file'] as List<String>,
            waitSeconds: wait,
          ),
        );
      },
    );
    run.argParser
      ..addOption(
        'project',
        help:
            'Flutter Android app directory; defaults to the current directory.',
      )
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'lib/main.dart',
        help: 'App entrypoint under lib/.',
      )
      ..addOption(
        'host',
        help: 'Override the detected LAN IPv4 address reachable by the phone.',
      )
      ..addOption(
        'flavor',
        help: 'Android product flavor used for the debug build.',
      )
      ..addMultiOption(
        'dart-define',
        splitCommas: false,
        help: 'Dart definition passed to both build and attach.',
      )
      ..addMultiOption(
        'dart-define-from-file',
        splitCommas: false,
        help: 'Definitions file passed to build and attach, relative to the app directory.',
      )
      ..addOption(
        'wait-timeout',
        defaultsTo: '600',
        help: 'Connection and reconnection timeout in seconds.',
      );
    addCommand(run);
    addCommand(
      ActionCommand('version', 'Print the CLI version.', (args) async {
        stdout.writeln('Airreload $cliVersion');
        return 0;
      }),
    );
    addCommand(
      ActionCommand(
        'doctor',
        'Check the patched Flutter SDK and required local tools.',
        (args) => operations.doctor(),
      ),
    );
    final host = ActionCommand(
      'host',
      'Start the TLS tunnel host. Creates private credentials on first use.',
      (args) async {
        if (!Platform.isMacOS && !Platform.isLinux) {
          throw StateError('Host currently supports macOS/Linux.');
        }
        final port = int.tryParse(args['port'] as String);
        if (port == null || port < 1 || port > 65535) {
          throw UsageException('Port must be between 1 and 65535.', usage);
        }
        await operations.host(port);
        return 0;
      },
    );
    host.argParser.addOption(
      'port',
      defaultsTo: '9443',
      help:
          'TLS listen port (non-default ports require companion-app support).',
    );
    addCommand(host);
    addCommand(
      ActionCommand(
        'status',
        'Report the host and app connection status; exit 1 if the host is offline.',
        (args) async {
          final session = await operations.session();
          stdout.writeln('Host active on TLS port ${session['port']}.');
          stdout.writeln(
            session['debugUrl'] == null
                ? 'App not connected.'
                : 'App connected; ready to attach.',
          );
          return 0;
        },
      ),
    );
    final pair = ActionCommand(
      'pair',
      'Print the active host pairing token and certificate fingerprint.',
      (args) async {
        final host = args['host'] as String?;
        final address = host == null ? null : InternetAddress.tryParse(host);
        if (address == null ||
            address.type != InternetAddressType.IPv4 ||
            address.isLoopback ||
            address.address == '0.0.0.0') {
          throw UsageException(
            'Provide --host with this computer\'s LAN IPv4 address.',
            usage,
          );
        }
        final session = await operations.session();
        final certificate = operations.workspace.certificate;
        final fingerprint = certificateFingerprint(
          await File(certificate).readAsString(),
        );
        stdout.writeln('Address: wss://$host:${session['port']}/connect');
        stdout.writeln('Pairing token: ${session['token']}');
        stdout.writeln('Certificate SHA-256: $fingerprint');
        stdout.writeln('Public certificate: $certificate');
        stdout.writeln(
          'The app must pin this certificate. Rebuild it before pairing if the APK was created for another host identity.',
        );
        return 0;
      },
    );
    pair.argParser.addOption(
      'host',
      help: 'This computer\'s LAN IPv4 address reachable by the phone.',
    );
    addCommand(pair);
    final attach = ActionCommand(
      'attach',
      'Attach to a connected compatible app for hot reload, hot restart, and DevTools. Does not install or launch the app.',
      (args) async {
        final project = args['project'] as String?;
        if (project == null || !await File('$project/pubspec.yaml').exists()) {
          throw UsageException(
            'Provide --project pointing to the matching Flutter source directory (with pubspec.yaml).',
            usage,
          );
        }
        final session = await operations.session();
        final url = session['debugUrl'] as String?;
        if (url == null) {
          throw StateError(
            'No compatible app is connected. Start host, then pair the app first.',
          );
        }
        final target = args['target'] as String?;
        return operations.attach(
          Directory(project).absolute.path,
          attachArguments(url, target),
        );
      },
    );
    attach.argParser.addOption(
      'project',
      help: 'Source project used to build the running debug app.',
    );
    attach.argParser.addOption(
      'target',
      help: 'Dart entrypoint used to build the running app.',
    );
    addCommand(attach);
  }
  final Operations operations;
}

class ActionCommand extends Command<int> {
  ActionCommand(this.name, this.description, this.action);
  @override
  final String name;
  @override
  final String description;
  final Future<int> Function(ArgResults) action;

  @override
  Future<int> run() {
    if (argResults!.rest.isNotEmpty) {
      usageException('Unexpected positional arguments.');
    }
    return action(argResults!);
  }
}

Future<int> runCli(List<String> args, Operations operations) async {
  if (args.length == 1 && args.single == '--version') args = ['version'];
  if (args.isEmpty) args = ['--help'];
  try {
    return await AirreloadRunner(operations).run(args) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return ExitCode.usage.code;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    return 1;
  } on SocketException catch (error) {
    stderr.writeln(
      'Network operation failed: ${error.message}. The requested port may already be in use.',
    );
    return ExitCode.unavailable.code;
  } on Object catch (error) {
    stderr.writeln('Airreload failed (${error.runtimeType}).');
    return 1;
  }
}
