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
          permission: ToolPermissionRequirement.none,
          validateArguments: (arguments) {
            final query = arguments['query'];
            return query is String && query.trim().isNotEmpty
                ? null
                : 'query is required';
          },
          localHandler: (call, context, cancellationToken) async {
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
      context: ToolContext(mode: ToolRunMode.live),
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
          permission: ToolPermissionRequirement.none,
          validateArguments: (_) => 'value is required',
          liveHandler: (_, _, _) async {
            executed = true;
            return null;
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'validated.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );

    expect(result.failure?.code, ToolErrorCode.invalidArguments);
    expect(executed, isFalse);
  });

  test('replay mode requires an explicitly replay-safe tool', () async {
    var executed = false;
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'live.tool',
          description: 'Has no replay fixture.',
          permission: ToolPermissionRequirement.none,
          liveHandler: (_, _, _) async {
            executed = true;
            return null;
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'live.tool'),
      context: ToolContext(mode: ToolRunMode.replay),
    );

    expect(result.failure?.code, ToolErrorCode.unsupportedMode);
    expect(executed, isFalse);
  });

  test('replay mode uses a dedicated fixture handler', () async {
    var liveExecuted = false;
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'fixture.tool',
          description: 'Has separate live and replay behavior.',
          permission: ToolPermissionRequirement.none,
          liveHandler: (_, _, _) async {
            liveExecuted = true;
            return 'live';
          },
          replayHandler: (_, _, _) async => 'fixture',
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'fixture.tool'),
      context: ToolContext(mode: ToolRunMode.replay),
    );

    expect(result.requireData<String>(), 'fixture');
    expect(liveExecuted, isFalse);
  });

  test('replay can use a narrower permission than the live handler', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'network.fixture',
          description: 'Network live, local fixture in replay.',
          permission: ToolPermissionRequirement.network,
          modePermissions: const <ToolRunMode, ToolPermissionRequirement>{
            ToolRunMode.replay: ToolPermissionRequirement.none,
          },
          liveHandler: (_, _, _) async => 'live',
          replayHandler: (_, _, _) async => 'fixture',
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'network.fixture'),
      context: ToolContext(mode: ToolRunMode.replay),
    );

    expect(result.requireData<String>(), 'fixture');
  });

  test('tool payloads are deeply copied and frozen', () {
    final nested = <String, Object?>{
      'filters': <Object?>[
        <String, Object?>{'domain': 'example.com'},
      ],
    };
    final metadata = <String, Object?>{
      'trace': <String, Object?>{'turn': 1},
    };
    final call = ToolCall(id: 'frozen', name: 'safe.tool', arguments: nested);
    final context = ToolContext(mode: ToolRunMode.live, metadata: metadata);

    (nested['filters']! as List<Object?>).clear();
    (metadata['trace']! as Map<String, Object?>)['turn'] = 2;

    final frozenFilters = call.arguments['filters']! as List<Object?>;
    final frozenDomain = frozenFilters.single as Map<String, Object?>;
    expect(frozenDomain['domain'], 'example.com');
    expect((context.metadata['trace']! as Map<String, Object?>)['turn'], 1);
    expect(() => frozenFilters.clear(), throwsUnsupportedError);
    expect(() => frozenDomain['domain'] = 'changed', throwsUnsupportedError);
  });

  test('tool call identifiers reject unsafe or oversized input', () {
    expect(
      () => ToolCall(id: 'bad\ncall', name: 'safe.tool'),
      throwsArgumentError,
    );
    expect(
      () => ToolCall(id: 'safe-call', name: 'bad\ntool'),
      throwsArgumentError,
    );
    expect(
      () =>
          ToolCall(id: List<String>.filled(129, 'a').join(), name: 'safe.tool'),
      throwsArgumentError,
    );
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
            liveHandler: (_, _, _) async {
              executed = true;
              return null;
            },
          ),
        );

      final result = await ToolRunner(registry: registry).run(
        call: ToolCall.create(name: 'network.tool'),
        context: ToolContext(mode: ToolRunMode.live),
      );

      expect(result.status, ToolResultStatus.permissionDenied);
      expect(result.failure?.code, ToolErrorCode.permissionDenied);
      expect(executed, isFalse);
    },
  );

  test('an injected permission policy can allow a protected tool', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'allowed.network.tool',
          description: 'Uses the network after authorization.',
          permission: ToolPermissionRequirement.network,
          liveHandler: (_, _, _) async => 'allowed',
        ),
      );
    final runner = ToolRunner(
      registry: registry,
      permissionPolicy: const _AllowPermissionPolicy(),
    );

    final result = await runner.run(
      call: ToolCall.create(name: 'allowed.network.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );

    expect(result.requireData<String>(), 'allowed');
  });

  test('times out and notifies a cooperative executor', () async {
    final cancellationObserved = Completer<void>();
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'slow.tool',
          description: 'Never completes on its own.',
          permission: ToolPermissionRequirement.none,
          timeout: const Duration(milliseconds: 20),
          liveHandler: (_, _, cancellationToken) async {
            await cancellationToken.whenCancelled;
            cancellationObserved.complete();
            return null;
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'slow.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );

    expect(result.status, ToolResultStatus.timedOut);
    expect(result.failure?.code, ToolErrorCode.timedOut);
    expect(result.failure?.retryable, isFalse);
    await expectLater(cancellationObserved.future, completes);
  });

  test(
    'a timed-out operation keeps its call id until it really settles',
    () async {
      final finishOperation = Completer<Object?>();
      final registry = ToolRegistry()
        ..register(
          ToolDefinition(
            name: 'noncooperative.tool',
            description: 'Ignores cancellation for testing.',
            permission: ToolPermissionRequirement.none,
            timeout: const Duration(milliseconds: 20),
            liveHandler: (_, _, _) => finishOperation.future,
          ),
        );
      final runner = ToolRunner(registry: registry);
      final call = ToolCall(id: 'same-call', name: 'noncooperative.tool');

      final timedOut = await runner.run(
        call: call,
        context: ToolContext(mode: ToolRunMode.live),
      );
      final duplicate = await runner.run(
        call: call,
        context: ToolContext(mode: ToolRunMode.live),
      );

      expect(timedOut.status, ToolResultStatus.timedOut);
      expect(timedOut.failure?.retryable, isFalse);
      expect(runner.inFlightCount, 1);
      expect(duplicate.failure?.code, ToolErrorCode.duplicateCall);

      finishOperation.complete('late');
      await Future<void>.delayed(Duration.zero);
      expect(runner.inFlightCount, 0);
    },
  );

  test('cancelActive releases the caller before a tool finishes', () async {
    final started = Completer<void>();
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'cancel.tool',
          description: 'Waits for cancellation.',
          permission: ToolPermissionRequirement.none,
          liveHandler: (_, _, cancellationToken) async {
            started.complete();
            await cancellationToken.whenCancelled;
            return null;
          },
        ),
      );
    final runner = ToolRunner(registry: registry);
    final future = runner.run(
      call: ToolCall.create(name: 'cancel.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );
    await started.future;

    runner.cancelActive(reason: 'generation stopped');
    final result = await future;

    expect(result.status, ToolResultStatus.cancelled);
    expect(result.failure?.message, 'Tool cancel.tool was cancelled.');
    expect(result.failure?.message, isNot(contains('generation stopped')));
    expect(runner.activeCount, 0);
  });

  test('cancel targets one call id without cancelling another call', () async {
    final started = <String, Completer<void>>{
      'first': Completer<void>(),
      'second': Completer<void>(),
    };
    final finishSecond = Completer<void>();
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'parallel.tool',
          description: 'Supports targeted cancellation.',
          permission: ToolPermissionRequirement.none,
          liveHandler: (call, _, cancellationToken) async {
            started[call.id]!.complete();
            if (call.id == 'first') {
              await cancellationToken.whenCancelled;
              return 'late';
            }
            await finishSecond.future;
            return 'second-result';
          },
        ),
      );
    final runner = ToolRunner(registry: registry);
    final first = runner.run(
      call: ToolCall(id: 'first', name: 'parallel.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );
    final second = runner.run(
      call: ToolCall(id: 'second', name: 'parallel.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );
    await Future.wait<void>(<Future<void>>[
      started['first']!.future,
      started['second']!.future,
    ]);

    expect(runner.cancel('first', reason: 'only first'), isTrue);
    expect(runner.cancel('missing'), isFalse);
    final firstResult = await first;
    finishSecond.complete();
    final secondResult = await second;

    expect(firstResult.status, ToolResultStatus.cancelled);
    expect(secondResult.requireData<String>(), 'second-result');
  });

  test('executor exceptions become retryable structured failures', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'failing.tool',
          description: 'Fails for testing.',
          permission: ToolPermissionRequirement.none,
          retryableOnFailure: true,
          liveHandler: (_, _, _) => Future<Object?>.error(StateError('boom')),
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'failing.tool'),
      context: ToolContext(mode: ToolRunMode.live),
    );

    expect(result.status, ToolResultStatus.failed);
    expect(result.failure?.code, ToolErrorCode.executionFailed);
    expect(result.failure?.retryable, isTrue);
    expect(result.failure?.message, isNot(contains('boom')));
  });

  test('executor can report a safe dynamic failure', () async {
    final registry = ToolRegistry()
      ..register(
        ToolDefinition(
          name: 'reported.failure',
          description: 'Returns a safe provider error.',
          permission: ToolPermissionRequirement.none,
          liveHandler: (_, _, _) async {
            throw ToolReportedException(
              safeMessage: 'Search provider is temporarily unavailable.',
              retryable: true,
              domainCode: 'provider_unavailable',
              safeDetails: const <String, Object?>{'status_code': 503},
            );
          },
        ),
      );

    final result = await ToolRunner(registry: registry).run(
      call: ToolCall.create(name: 'reported.failure'),
      context: ToolContext(mode: ToolRunMode.live),
    );

    expect(
      result.failure?.message,
      'Search provider is temporarily unavailable.',
    );
    expect(result.failure?.message, isNot(contains('secret-bearing')));
    expect(result.failure?.retryable, isTrue);
    expect(result.failure?.domainCode, 'provider_unavailable');
    expect(result.failure?.safeDetails, const <String, Object?>{
      'status_code': 503,
    });
    expect(
      () => result.failure!.safeDetails['status_code'] = 200,
      throwsUnsupportedError,
    );
    expect(
      () => ToolReportedException(
        safeMessage: 'Unsafe details.',
        domainCode: 'provider.failure',
        safeDetails: const <String, Object?>{'score': double.nan},
      ),
      throwsArgumentError,
    );
  });

  test('registry refuses accidental duplicate registrations', () {
    final definition = ToolDefinition(
      name: 'same.tool',
      description: 'A tool.',
      permission: ToolPermissionRequirement.none,
      liveHandler: (_, _, _) async => null,
    );
    final registry = ToolRegistry()..register(definition);

    expect(() => registry.register(definition), throwsStateError);
  });
}

class _AllowPermissionPolicy implements ToolPermissionPolicy {
  const _AllowPermissionPolicy();

  @override
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    return ToolPermissionDecision.allow;
  }
}
