import 'dart:developer' as developer;

/// A system-context fragment whose state changes are committed only after the
/// fragment was actually sent and the model request completed successfully.
///
/// Prompt builders must stay read-only. Cooldowns, counters, and queue
/// consumption belong in [commit], which is idempotent.
class DeferredPrompt {
  final String text;
  final Future<void> Function()? _onCommit;
  bool _committed = false;

  DeferredPrompt(this.text, {Future<void> Function()? onCommit})
    : _onCommit = onCommit;

  DeferredPrompt.empty() : text = '', _onCommit = null;

  bool get isNotEmpty => text.trim().isNotEmpty;
  bool get isCommitted => _committed || !isNotEmpty;

  Future<void> commit() async {
    if (_committed || !isNotEmpty) return;
    await _onCommit?.call();
    _committed = true;
  }
}

/// One outgoing turn can contain several independently produced fragments.
/// Committing the batch after a successful request prevents ghost consumption.
class DeferredPromptBatch {
  final List<DeferredPrompt> _prompts = [];
  bool _committed = false;

  void add(DeferredPrompt prompt) {
    if (prompt.isNotEmpty) _prompts.add(prompt);
  }

  Future<void> commit() async {
    if (_committed) return;
    for (final prompt in _prompts) {
      try {
        await prompt.commit();
      } catch (error, stackTrace) {
        developer.log(
          'Deferred system-context commit failed; it will be retried.',
          name: 'DeferredPromptBatch',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _committed = _prompts.every((prompt) => prompt.isCommitted);
  }
}
