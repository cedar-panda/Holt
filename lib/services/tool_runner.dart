import 'dart:async';

Map<String, Object?> _deepFreezeJsonMap(
  Map<String, Object?> source,
  String label,
) {
  final frozen = <String, Object?>{};
  for (final entry in source.entries) {
    frozen[entry.key] = _deepFreezeJson(entry.value, '$label.${entry.key}');
  }
  return Map<String, Object?>.unmodifiable(frozen);
}

Object? _deepFreezeJson(Object? value, String path) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(<Object?>[
      for (var i = 0; i < value.length; i++)
        _deepFreezeJson(value[i], '$path[$i]'),
    ]);
  }
  if (value is Map) {
    final frozen = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(
          key,
          path,
          'Tool payload map keys must be strings.',
        );
      }
      frozen[key] = _deepFreezeJson(entry.value, '$path.$key');
    }
    return Map<String, Object?>.unmodifiable(frozen);
  }
  throw ArgumentError.value(
    value,
    path,
    'Tool payloads must contain only JSON-compatible values.',
  );
}

/// 工具需要取得的權限層級。
///
/// [none] 代表純本地、無副作用的操作，可直接執行。其餘層級必須交給
/// [ToolPermissionPolicy] 決定；ToolRunner 的預設策略會拒絕所有受保護操作，
/// 避免新工具忘記接 UI 確認時意外放行。
enum ToolPermissionRequirement {
  none,
  sensitiveRead,
  network,
  localMutation,
  externalSideEffect,
}

enum ToolPermissionDecision { allow, deny }

/// 工具資料來源。Replay 絕不能意外落到 live executor。
enum ToolRunMode { local, replay, live }

enum ToolResultStatus { success, failed, cancelled, timedOut, permissionDenied }

enum ToolErrorCode {
  unknownTool,
  duplicateCall,
  invalidArguments,
  unsupportedMode,
  permissionDenied,
  cancelled,
  timedOut,
  executionFailed,
}

/// 一次模型或 App 提出的工具請求。
///
/// XML、provider 原生 tool call 與未來 MCP 呼叫都應先正規化成這個型別，
/// ToolRunner 不需要知道呼叫原本採用哪種協議。
class ToolCall {
  ToolCall({
    required this.id,
    required this.name,
    Map<String, Object?> arguments = const <String, Object?>{},
  }) : arguments = _deepFreezeJsonMap(arguments, 'arguments');

  factory ToolCall.create({
    required String name,
    Map<String, Object?> arguments = const <String, Object?>{},
  }) {
    final sequence = _nextSequence++;
    return ToolCall(
      id: 'tool_${DateTime.now().microsecondsSinceEpoch}_$sequence',
      name: name,
      arguments: arguments,
    );
  }

  static int _nextSequence = 0;

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

/// 不屬於模型對話正文的執行背景。
class ToolContext {
  ToolContext({
    required this.mode,
    this.conversationId,
    this.characterId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : metadata = _deepFreezeJsonMap(metadata, 'metadata');

  final String? conversationId;
  final String? characterId;
  final ToolRunMode mode;
  final Map<String, Object?> metadata;
}

/// 工具可以主動檢查的協作式取消信號。
class ToolCancellationToken {
  ToolCancellationToken._();

  final Completer<String?> _cancelled = Completer<String?>();
  final Set<void Function(String?)> _listeners = <void Function(String?)>{};
  bool _isCancelled = false;
  String? _reason;

  bool get isCancelled => _isCancelled;
  String? get reason => _reason;
  Future<String?> get whenCancelled => _cancelled.future;

  void throwIfCancelled() {
    if (_isCancelled) throw ToolCancelledException(_reason);
  }

  /// 註冊同步取消清理，回傳的函式可解除監聽，避免長生命週期的上游 token
  /// 持有已完成 ToolCall 的 controller。
  void Function() addListener(void Function(String?) listener) {
    if (_isCancelled) {
      listener(_reason);
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _cancel(String? reason) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    _cancelled.complete(reason);
    final listeners = List<void Function(String?)>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener(reason);
      } catch (_) {
        // 取消是 best-effort fan-out；一個 executor 的清理失敗不能阻止其他
        // active tool 收到取消，也不能改寫 Runner 對呼叫端的取消結果。
      }
    }
  }
}

class ToolCancellationController {
  ToolCancellationController() : token = ToolCancellationToken._();

  final ToolCancellationToken token;

  void cancel([String? reason]) => token._cancel(reason);
}

class ToolCancelledException implements Exception {
  const ToolCancelledException([this.reason]);

  final String? reason;

  @override
  String toString() => reason == null || reason!.isEmpty
      ? 'Tool execution was cancelled.'
      : 'Tool execution was cancelled: $reason';
}

/// Executor 可用它回報輸入或必要 context 不合法；Runner 會正規化為
/// [ToolErrorCode.invalidArguments]，而不是一般執行錯誤。
class ToolInputException implements Exception {
  const ToolInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ToolFailure {
  const ToolFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.cause,
    this.stackTrace,
  });

  final ToolErrorCode code;
  final String message;
  final bool retryable;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => message;
}

class ToolResult {
  const ToolResult._({
    required this.callId,
    required this.toolName,
    required this.status,
    required this.elapsed,
    this.data,
    this.failure,
  });

  factory ToolResult.success({
    required ToolCall call,
    required Duration elapsed,
    Object? data,
  }) {
    return ToolResult._(
      callId: call.id,
      toolName: call.name,
      status: ToolResultStatus.success,
      elapsed: elapsed,
      data: data,
    );
  }

  factory ToolResult.failure({
    required ToolCall call,
    required ToolResultStatus status,
    required Duration elapsed,
    required ToolFailure failure,
  }) {
    assert(status != ToolResultStatus.success);
    return ToolResult._(
      callId: call.id,
      toolName: call.name,
      status: status,
      elapsed: elapsed,
      failure: failure,
    );
  }

  final String callId;
  final String toolName;
  final ToolResultStatus status;
  final Duration elapsed;
  final Object? data;
  final ToolFailure? failure;

  bool get isSuccess => status == ToolResultStatus.success;
  bool get isCancelled => status == ToolResultStatus.cancelled;

  T requireData<T>() {
    if (!isSuccess) throw ToolRunException(this);
    final value = data;
    if (value is! T) {
      throw StateError(
        'Tool $toolName returned ${value.runtimeType}; expected $T.',
      );
    }
    return value;
  }
}

class ToolRunException implements Exception {
  const ToolRunException(this.result);

  final ToolResult result;

  @override
  String toString() =>
      result.failure?.message ??
      'Tool ${result.toolName} ended with ${result.status.name}.';
}

typedef ToolArgumentsValidator =
    String? Function(Map<String, Object?> arguments);

typedef ToolHandler =
    Future<Object?> Function(
      ToolCall call,
      ToolContext context,
      ToolCancellationToken cancellationToken,
    );

class ToolDefinition {
  ToolDefinition({
    required this.name,
    required this.description,
    required this.permission,
    ToolHandler? localHandler,
    ToolHandler? replayHandler,
    ToolHandler? liveHandler,
    this.timeout = const Duration(seconds: 15),
    this.validateArguments,
    this.retryableOnFailure = false,
    this.retryableOnTimeout = false,
  }) : _handlers = Map<ToolRunMode, ToolHandler>.unmodifiable(
         <ToolRunMode, ToolHandler>{
           ToolRunMode.local: ?localHandler,
           ToolRunMode.replay: ?replayHandler,
           ToolRunMode.live: ?liveHandler,
         },
       ) {
    if (!_validName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Invalid tool name.');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Tool timeout must be greater than zero.',
      );
    }
    if (_handlers.isEmpty) {
      throw ArgumentError.value(
        _handlers,
        'handlers',
        'At least one mode-specific tool handler is required.',
      );
    }
  }

  static final RegExp _validName = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  final String name;
  final String description;
  final Duration timeout;
  final ToolPermissionRequirement permission;
  final ToolArgumentsValidator? validateArguments;
  final bool retryableOnFailure;
  final bool retryableOnTimeout;
  final Map<ToolRunMode, ToolHandler> _handlers;

  bool supportsMode(ToolRunMode mode) => _handlers.containsKey(mode);

  ToolHandler? handlerFor(ToolRunMode mode) => _handlers[mode];
}

class ToolRegistry {
  final Map<String, ToolDefinition> _definitions = <String, ToolDefinition>{};

  Iterable<ToolDefinition> get definitions =>
      List<ToolDefinition>.unmodifiable(_definitions.values);

  ToolDefinition? lookup(String name) => _definitions[name];

  void register(ToolDefinition definition, {bool replace = false}) {
    if (!replace && _definitions.containsKey(definition.name)) {
      throw StateError('Tool ${definition.name} is already registered.');
    }
    _definitions[definition.name] = definition;
  }

  bool unregister(String name) => _definitions.remove(name) != null;
}

abstract interface class ToolPermissionPolicy {
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  });
}

/// 安全預設：只有 [ToolPermissionRequirement.none] 會由 Runner 直接放行；
/// 任何受保護工具在尚未接入 UI 權限策略前都拒絕執行。
class DenyProtectedToolPermissionPolicy implements ToolPermissionPolicy {
  const DenyProtectedToolPermissionPolicy();

  @override
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    return ToolPermissionDecision.deny;
  }
}

class ToolRunner {
  ToolRunner({
    required this.registry,
    this.permissionPolicy = const DenyProtectedToolPermissionPolicy(),
  });

  final ToolRegistry registry;
  final ToolPermissionPolicy permissionPolicy;
  final Map<String, ToolCancellationController> _active =
      <String, ToolCancellationController>{};
  final Set<String> _inFlight = <String>{};

  int get activeCount => _active.length;
  int get inFlightCount => _inFlight.length;

  Future<ToolResult> run({
    required ToolCall call,
    required ToolContext context,
    ToolCancellationToken? cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final definition = registry.lookup(call.name);
    if (definition == null) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.unknownTool,
        message: 'Unknown tool: ${call.name}.',
      );
    }

    if (_inFlight.contains(call.id)) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.duplicateCall,
        message: 'Tool call ${call.id} is already running.',
      );
    }

    if (!definition.supportsMode(context.mode)) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.unsupportedMode,
        message:
            'Tool ${call.name} does not support ${context.mode.name} mode.',
      );
    }

    try {
      final validationError = definition.validateArguments?.call(
        call.arguments,
      );
      if (validationError != null) {
        return _failed(
          call: call,
          stopwatch: stopwatch,
          status: ToolResultStatus.failed,
          code: ToolErrorCode.invalidArguments,
          message: validationError,
        );
      }
    } catch (error, stackTrace) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.invalidArguments,
        message: 'Unable to validate ${call.name} arguments.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    final controller = ToolCancellationController();
    _active[call.id] = controller;
    _inFlight.add(call.id);
    void Function()? unlinkCancellation;
    if (cancellationToken != null) {
      unlinkCancellation = cancellationToken.addListener(controller.cancel);
    }

    Future<Object?>? operation;
    try {
      controller.token.throwIfCancelled();
      operation = _execute(
        call: call,
        context: context,
        definition: definition,
        cancellationToken: controller.token,
      );
      _releaseInFlightWhenSettled(call.id, operation);
      final data = await _raceCancellation(operation, controller.token).timeout(
        definition.timeout,
        onTimeout: () {
          controller.cancel('Timed out after ${definition.timeout}.');
          throw const _ToolTimeoutException();
        },
      );
      controller.token.throwIfCancelled();
      stopwatch.stop();
      return ToolResult.success(
        call: call,
        elapsed: stopwatch.elapsed,
        data: data,
      );
    } on _ToolPermissionDeniedException {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.permissionDenied,
        code: ToolErrorCode.permissionDenied,
        message: 'Permission denied for tool ${call.name}.',
      );
    } on ToolInputException catch (error, stackTrace) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.invalidArguments,
        message: error.message,
        cause: error,
        stackTrace: stackTrace,
      );
    } on _ToolTimeoutException {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.timedOut,
        code: ToolErrorCode.timedOut,
        message: 'Tool ${call.name} timed out after ${definition.timeout}.',
        retryable: definition.retryableOnTimeout,
      );
    } on ToolCancelledException catch (error, stackTrace) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.cancelled,
        code: ToolErrorCode.cancelled,
        message: error.toString(),
        cause: error,
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      return _failed(
        call: call,
        stopwatch: stopwatch,
        status: ToolResultStatus.failed,
        code: ToolErrorCode.executionFailed,
        message: 'Tool ${call.name} failed.',
        retryable: definition.retryableOnFailure,
        cause: error,
        stackTrace: stackTrace,
      );
    } finally {
      unlinkCancellation?.call();
      if (identical(_active[call.id], controller)) {
        _active.remove(call.id);
      }
      if (operation == null) _inFlight.remove(call.id);
    }
  }

  bool cancel(String callId, {String? reason}) {
    final controller = _active[callId];
    if (controller == null) return false;
    controller.cancel(reason ?? 'Cancelled by caller.');
    return true;
  }

  void cancelActive({String? reason}) {
    final controllers = List<ToolCancellationController>.of(_active.values);
    for (final controller in controllers) {
      controller.cancel(reason ?? 'Cancelled by caller.');
    }
  }

  Future<Object?> _execute({
    required ToolCall call,
    required ToolContext context,
    required ToolDefinition definition,
    required ToolCancellationToken cancellationToken,
  }) async {
    if (definition.permission != ToolPermissionRequirement.none) {
      final decision = await permissionPolicy.requestPermission(
        call: call,
        definition: definition,
        context: context,
        cancellationToken: cancellationToken,
      );
      cancellationToken.throwIfCancelled();
      if (decision != ToolPermissionDecision.allow) {
        throw const _ToolPermissionDeniedException();
      }
    }

    cancellationToken.throwIfCancelled();
    final handler = definition.handlerFor(context.mode);
    if (handler == null) {
      throw ToolInputException(
        'Tool ${call.name} does not support ${context.mode.name} mode.',
      );
    }
    return handler(call, context, cancellationToken);
  }

  void _releaseInFlightWhenSettled(String callId, Future<Object?> operation) {
    unawaited(
      operation.then<void>(
        (_) => _inFlight.remove(callId),
        onError: (Object _, StackTrace _) {
          _inFlight.remove(callId);
        },
      ),
    );
  }

  Future<Object?> _raceCancellation(
    Future<Object?> operation,
    ToolCancellationToken cancellationToken,
  ) {
    return Future.any<Object?>(<Future<Object?>>[
      operation,
      cancellationToken.whenCancelled.then<Object?>((reason) {
        throw ToolCancelledException(reason);
      }),
    ]);
  }

  ToolResult _failed({
    required ToolCall call,
    required Stopwatch stopwatch,
    required ToolResultStatus status,
    required ToolErrorCode code,
    required String message,
    bool retryable = false,
    Object? cause,
    StackTrace? stackTrace,
  }) {
    stopwatch.stop();
    return ToolResult.failure(
      call: call,
      status: status,
      elapsed: stopwatch.elapsed,
      failure: ToolFailure(
        code: code,
        message: message,
        retryable: retryable,
        cause: cause,
        stackTrace: stackTrace,
      ),
    );
  }
}

class _ToolPermissionDeniedException implements Exception {
  const _ToolPermissionDeniedException();
}

class _ToolTimeoutException implements Exception {
  const _ToolTimeoutException();
}
