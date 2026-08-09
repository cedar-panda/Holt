import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/tool_runner.dart';

void main() {
  test('runs a registered tool and returns typed data', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'chat.search',
          description: 'Search local chat history.',
          validateArguments: (arguments) {
            final query = arguments['query'];
            return query is String && query.trim().isNotEmpty
                ? null
                : 'query is required';
          },
          handler: (call, context, cancellationToken) async {
            cancellationToken.throwIfCancelled();
            return <String>[
              '${context.characterId}:${call.arguments['query']}',
            ];
          },
        ),
      );
    final runner = ToolRunner(registry: registry);

    final result = await runner.run(
      call: ToolCall.create(
        name: 'chat.search',
        arguments: const <String, Object?>{'query': '約定'},
      ),
      context: ToolContext(characterId: 'char-1', mode: ToolRunMode.local),
    );

    expect(result.status, ToolResultStatus.success);
    expect(result.requireData<List<String>>(), <String>['char-1:約定']);
    expect(runner.activeCount, 0);
  });

  test('rejects unknown tools without executing anything', () async {
    final runner = ToolRunner(registry: ToolRegistry());

    final result = await runner.run(
      call: ToolCall.create(name: 'missing.tool'),
      context: ToolContext(),
    );

    expect(result.status, ToolResultStatus.failed);
    expect(result.failure?.code, ToolErrorCode.unknownTool);
  });

  test('invalid arguments never reach the handler', () async {
    var executed = false;
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'validated.tool',
          description: 'Requires a value.',
          validateArguments: (_) => 'value is required',
          handler: (_, _, _) async {
            executed = true;
            return null;
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'validated.tool'),
      context: ToolContext(),
    );

    expect(result.failure?.code, ToolErrorCode.invalidArguments);
    expect(executed, isFalse);
  });

  test(
    'protected tools are denied until a permission policy allows them',
    () async {
      var executed = false;
      final registry = ToolRegistry()
        ..register(
          ToolDefinition(
            name: 'network.tool',
            description: 'Uses the network.',
            permission: ToolPermissionRequirement.network,
            handler: (_, _, _) async {
              executed = true;
              return null;
            },
          ),
        );

      final result = await ToolRunner(registry: registry).run(
        call: ToolCall.create(name: 'network.tool'),
        context: ToolContext(),
      );

      expect(result.status, ToolResultStatus.permissionDenied);
      expect(result.failure?.code, ToolErrorCode.permissionDenied);
      expect(executed, isFalse);
    },
  );

  test('times out and notifies a cooperative executor', () async {
    final cancellationObserved = Completer<void>();
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'slow.tool',
          description: 'Never completes on its own.',
          timeout: const Duration(milliseconds: 20),
          handler: (_, _, cancellationToken) async {
            await cancellationToken.whenCancelled;
            cancellationObserved.complete();
            return null;
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'slow.tool'),
      context: ToolContext(),
    );

    expect(result.status, ToolResultStatus.timedOut);
    expect(result.failure?.code, ToolErrorCode.timedOut);
    await expectLater(cancellationObserved.future, completes);
  });

  test('cancelActive releases the caller before a tool finishes', () async {
    final started = Completer<void>();
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'cancel.tool',
          description: 'Waits for cancellation.',
          handler: (_, _, cancellationToken) async {
            started.complete();
            await cancellationToken.whenCancelled;
            return null;
          },
        ),
      );
    final runner = ToolRunner(registry: registry);
    final future = runner.run(
      call: ToolCall.create(name: 'cancel.tool'),
      context: ToolContext(),
    );
    await started.future;

    runner.cancelActive(reason: 'generation stopped');
    final result = await future;

    expect(result.status, ToolResultStatus.cancelled);
    expect(result.failure?.message, contains('generation stopped'));
    expect(runner.activeCount, 0);
  });

  test('executor exceptions become retryable structured failures', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'failing.tool',
          description: 'Fails for testing.',
          retryableOnFailure: true,
          handler: (_, _, _) => Future<Object?>.error(StateError('boom')),
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'failing.tool'),
      context: ToolContext(),
    );

    expect(result.status, ToolResultStatus.failed);
    expect(result.failure?.code, ToolErrorCode.executionFailed);
    expect(result.failure?.retryable, isTrue);
    expect(result.failure?.cause, isA<StateError>());
  });

  test('registry refuses accidental duplicate registrations', () {
    final definition = ToolDefinition(
      name: 'same.tool',
      description: 'A tool.',
      handler: (_, _, _) async => null,
    );
    final registry = ToolRegistry()..register(definition);

    expect(() => registry.register(definition), throwsStateError);
  });
}
