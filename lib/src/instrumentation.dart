import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'android_runtime.dart';
import 'runtime_template.dart';
import 'platform_support.dart';
import 'workspace.dart';

String dartLiteral(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

String entrypointWrapper(String importUri, String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final main = unit.declarations
      .whereType<FunctionDeclaration>()
      .where((d) => d.name.lexeme == 'main')
      .firstOrNull;
  if (main == null) {
    throw StateError(
      'The selected target must declare a top-level main function.',
    );
  }
  final parameters =
      main.functionExpression.parameters?.parameters ?? <FormalParameter>[];
  if (parameters.length > 1 ||
      parameters.any((parameter) => parameter.isNamed)) {
    throw StateError(
      'Supported main signatures: main() or main(List<String> args).',
    );
  }
  final call = parameters.isEmpty ? 'app.main()' : 'app.main(const <String>[])';
  return "import 'dart:async';\nimport ${dartLiteral(importUri)} as app;\nimport 'runtime.dart';\n"
      'Future<void> main() async {\n  startAirreload();\n  await Future<void>.sync(() => $call);\n}\n';
}

const _excluded = {
  '.git',
  '.dart_tool',
  'build',
  '.gradle',
  '.idea',
  'node_modules',
  '.airreload',
  '.fvm',
};

class PreparedProject {
  PreparedProject(this.original, this.directory, this.target);
  final String original;
  final String directory;
  final String target;

  static Future<PreparedProject> create({
    required String source,
    required String destination,
    required String target,
    required Workspace sdk,
    required String host,
    required int port,
    required String token,
    required String certificate,
  }) async {
    source = p.normalize(p.absolute(source));
    final spec = File(p.join(source, 'pubspec.yaml'));
    if (!await spec.exists() ||
        !await Directory(p.join(source, 'android')).exists()) {
      throw StateError(
        'Run from a Flutter Android app directory containing pubspec.yaml and android/.',
      );
    }
    final yaml = loadYaml(await spec.readAsString()) as YamlMap;
    if (yaml.containsKey('workspace') || yaml['resolution'] == 'workspace') {
      throw StateError(
        'Pub workspaces are not supported by run yet. Use a standalone Flutter app.',
      );
    }
    final selected = p.normalize(
      p.isAbsolute(target) ? target : p.join(source, target),
    );
    if (!p.isWithin(p.join(source, 'lib'), selected) ||
        !await File(selected).exists()) {
      throw StateError(
        '--target must be an existing Dart file under the app\'s lib/ directory.',
      );
    }
    final name = yaml['name'] as String;
    final wrapper = entrypointWrapper(
      'package:$name/${p.relative(selected, from: p.join(source, 'lib')).replaceAll(p.separator, '/')}',
      await File(selected).readAsString(),
    );
    await Directory(destination).create(recursive: true);
    await _copyDirectory(Directory(source), Directory(destination), source);
    // Flutter's Gradle integration must use the SDK selected for this run,
    // even when the source app's local.properties points at FVM or another SDK.
    final properties = File(p.join(destination, 'android', 'local.properties'));
    final existingProperties = await properties.exists()
        ? await properties.readAsLines()
        : <String>[];
    final flutterPath = sdk.sdkRoot
        .replaceAll('\\', '\\\\')
        .replaceAll(':', '\\:');
    await properties.writeAsString(
      [
        ...existingProperties.where(
          (line) => !RegExp(r'^\s*flutter\.sdk\s*[:=]').hasMatch(line),
        ),
        'flutter.sdk=$flutterPath',
        '',
      ].join('\n'),
    );
    await createDirectoryLink(
      p.join(destination, 'lib'),
      p.join(source, 'lib'),
    );
    for (final filename in ['pubspec.yaml', 'pubspec_overrides.yaml']) {
      final file = File(p.join(destination, filename));
      if (!await file.exists()) continue;
      final content = await file.readAsString();
      final document = loadYaml(content);
      if (document is! YamlMap) continue;
      if (document['resolution'] == 'workspace') {
        throw StateError('Pub workspace overrides are not supported.');
      }
      final editor = YamlEditor(content);
      for (final section in [
        'dependencies',
        'dev_dependencies',
        'dependency_overrides',
      ]) {
        final dependencies = document[section];
        if (dependencies is! YamlMap) continue;
        for (final name in dependencies.keys) {
          final dependency = dependencies[name];
          if (dependency is YamlMap && dependency['path'] is String) {
            editor.update([
              section,
              name,
              'path',
            ], p.normalize(p.join(source, dependency['path'] as String)));
          }
        }
      }
      await file.writeAsString(editor.toString());
    }
    final generated = Directory(p.join(destination, '.dart_tool', 'airreload'));
    await generated.create(recursive: true);
    await File(p.join(generated.path, 'entrypoint.dart'))
        .writeAsString(wrapper);
    await File(p.join(generated.path, 'runtime.dart'))
        .writeAsString(runtimeTemplate);
    await File(p.join(generated.path, 'config.dart')).writeAsString(
      'const computerHost = ${dartLiteral(host)};\nconst tunnelPort = $port;\n'
      'const sessionToken = ${dartLiteral(token)};\nconst certificatePin = ${dartLiteral(base64Encode(certificateDer(certificate)))};\n',
    );
    await injectAirreloadAndroidRuntime(
      destination: destination,
      host: host,
      port: port,
      token: token,
      certificatePin: base64Encode(certificateDer(certificate)),
    );
    return PreparedProject(
      source,
      destination,
      p.join(generated.path, 'entrypoint.dart'),
    );
  }
}

Future<void> _copyDirectory(
  Directory source,
  Directory destination,
  String root,
) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (_excluded.contains(name) || (source.path == root && name == 'lib')) {
      continue;
    }
    final target = p.join(destination.path, name);
    if (entity is Directory) {
      await Directory(target).create();
      await _copyDirectory(entity, Directory(target), root);
    } else if (entity is File) {
      await entity.copy(target);
    } else if (entity is Link) {
      final resolved = await entity.resolveSymbolicLinks();
      final type = await FileSystemEntity.type(resolved);
      if (type == FileSystemEntityType.directory) {
        await Directory(target).create();
        await _copyDirectory(Directory(resolved), Directory(target), root);
      } else if (type == FileSystemEntityType.file) {
        await File(resolved).copy(target);
      }
    }
  }
}
