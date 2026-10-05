/// Immutable context domain for one conversation window.
///
/// This is deliberately separate from legacy memory strategy/bucket values
/// such as daily, story, custom, and romance.
enum ContextMode {
  daily('daily'),
  rp('rp');

  const ContextMode(this.storageValue);

  final String storageValue;

  static ContextMode fromStorage(Object? raw) {
    final value = raw?.toString().trim();
    return switch (value) {
      'daily' => ContextMode.daily,
      'rp' => ContextMode.rp,
      _ => throw StateError('Invalid conversation context_mode: $raw'),
    };
  }
}
