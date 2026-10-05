import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Foreground colors derived from the dominant tone of a background image.
///
/// Backgrounds remain untouched. Only text and small functional glyphs use
/// these opaque colors, so image-backed pages stay clear without a dirty veil.
class BackgroundForegroundPalette {
  const BackgroundForegroundPalette({
    required this.dominant,
    required this.primary,
    required this.secondary,
    required this.subtle,
  });

  final Color dominant;
  final Color primary;
  final Color secondary;
  final Color subtle;
}

/// Bubble + input bar colors auto-derived from a chat background image.
///
/// Stored as opaque base colors; the caller applies alpha separately so that
/// the user's bubble-opacity slider keeps working.
class ChatBubblePalette {
  const ChatBubblePalette({
    required this.aiBubble,
    required this.userBubble,
    required this.bubbleText,
    required this.thinkingText,
    required this.bubbleOpacity,
    required this.inputBarBg,
    required this.inputBarBorder,
    required this.inputBarText,
  });

  final Color aiBubble;
  final Color userBubble;
  final Color bubbleText;
  final Color thinkingText;
  final double bubbleOpacity;
  final Color inputBarBg;
  final Color inputBarBorder;
  final Color inputBarText;
}

class BackgroundForegroundService {
  BackgroundForegroundService._();

  static final Map<String, BackgroundForegroundPalette> _cache =
      <String, BackgroundForegroundPalette>{};

  static final Map<String, ChatBubblePalette> _bubbleCache =
      <String, ChatBubblePalette>{};

  static BackgroundForegroundPalette? cached(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty || !File(normalized).existsSync()) {
      invalidate(normalized);
      return null;
    }
    return _cache[normalized];
  }

  static void invalidate(String path) {
    final normalized = path.trim();
    _cache.remove(normalized);
    _bubbleCache.remove(normalized);
  }

  static BackgroundForegroundPalette forColor(Color color) =>
      _derivePalette(color);

  static Future<BackgroundForegroundPalette?> resolve(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return null;
    final file = File(normalized);
    if (!await file.exists()) {
      invalidate(normalized);
      return null;
    }
    final cachedPalette = _cache[normalized];
    if (cachedPalette != null) return cachedPalette;

    ui.Codec? codec;
    ui.Image? image;
    try {
      // Decode a tiny analysis copy only. The displayed background continues
      // to use the untouched original file at full source quality.
      codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 48,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;

      final buckets = <int, _ColorBucket>{};
      final bytes = data.buffer.asUint8List();
      for (var offset = 0; offset + 3 < bytes.length; offset += 4) {
        if (bytes[offset + 3] < 128) continue;
        final r = bytes[offset];
        final g = bytes[offset + 1];
        final b = bytes[offset + 2];
        final key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5);
        (buckets[key] ??= _ColorBucket()).add(r, g, b);
      }
      if (buckets.isEmpty) return null;

      final dominantBucket = buckets.values.reduce(
        (a, b) => a.count >= b.count ? a : b,
      );
      final dominant = dominantBucket.color;
      final palette = _derivePalette(dominant);
      _cache[normalized] = palette;
      return palette;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// Resolve a [ChatBubblePalette] for the chat background at [path].
  ///
  /// Returns `null` when [path] is empty or the file cannot be decoded.
  /// Results are cached by path, same as [resolve].
  static Future<ChatBubblePalette?> resolveChatBubblePalette(
    String path,
  ) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return null;
    if (!await File(normalized).exists()) {
      _bubbleCache.remove(normalized);
      _cache.remove(normalized);
      return null;
    }
    final cached = _bubbleCache[normalized];
    if (cached != null) return cached;

    // Reuse the foreground palette resolve which already extracts dominant.
    final fg = await resolve(normalized);
    if (fg == null) return null;

    final palette = _deriveChatBubblePalette(fg.dominant);
    _bubbleCache[normalized] = palette;
    return palette;
  }

  static ChatBubblePalette? cachedChatBubblePalette(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty || !File(normalized).existsSync()) return null;
    return _bubbleCache[normalized];
  }

  /// Derive bubble + input bar colors from the dominant tone of a chat
  /// background image.
  ///
  /// Design goals:
  ///  • Bubbles carry the background's hue at very low saturation — tinted,
  ///    not coloured — so they harmonise without competing.
  ///  • Lightness sits on the opposite side of the background (dark bg →
  ///    light bubbles, light bg → dark bubbles) for natural contrast.
  ///  • User bubble shifts hue ~25° for visual separation while staying in
  ///    the same colour family.
  ///  • Text colours pass WCAG AA (≥ 4.5 : 1) against the opaque bubble.
  ///  • Input bar follows the same tint at a slightly higher opacity to keep
  ///    the glass feel but read clearly.
  static ChatBubblePalette _deriveChatBubblePalette(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    final bgLuminance = dominant.computeLuminance();
    final isDarkBg = bgLuminance < 0.4;

    // ── AI bubble ──────────────────────────────────────────────
    final aiBubble = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.15).clamp(0.03, 0.12),
      isDarkBg ? 0.16 : 0.93,
    ).toColor();

    // ── User bubble (hue +25°, slightly more saturated) ───────
    final userBubble = HSLColor.fromAHSL(
      1,
      (hsl.hue + 25) % 360,
      (hsl.saturation * 0.22).clamp(0.05, 0.18),
      isDarkBg ? 0.21 : 0.88,
    ).toColor();

    // ── Text on bubbles ───────────────────────────────────────
    final textFallback = isDarkBg ? Colors.white : Colors.black;
    final textCandidate = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.06).clamp(0.02, 0.08),
      isDarkBg ? 0.92 : 0.10,
    ).toColor();
    final bubbleText = _ensureContrast(
      textCandidate,
      aiBubble,
      textFallback,
      minimum: 4.5,
    );

    // ── Thinking text (softer) ────────────────────────────────
    final thinkingCandidate = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.08).clamp(0.03, 0.10),
      isDarkBg ? 0.78 : 0.28,
    ).toColor();
    final thinkingText = _ensureContrast(
      thinkingCandidate,
      aiBubble,
      isDarkBg ? const Color(0xB3FFFFFF) : const Color(0x8A000000),
      minimum: 3.0,
    );

    // ── Input bar ─────────────────────────────────────────────
    final inputBarBg = HSLColor.fromAHSL(
      isDarkBg ? 0.82 : 0.88,
      hsl.hue,
      (hsl.saturation * 0.10).clamp(0.02, 0.08),
      isDarkBg ? 0.14 : 0.96,
    ).toColor();

    final inputBarBorder = HSLColor.fromAHSL(
      isDarkBg ? 0.15 : 0.20,
      hsl.hue,
      (hsl.saturation * 0.18).clamp(0.04, 0.14),
      isDarkBg ? 0.50 : 0.60,
    ).toColor();

    return ChatBubblePalette(
      aiBubble: aiBubble,
      userBubble: userBubble,
      bubbleText: bubbleText,
      thinkingText: thinkingText,
      bubbleOpacity: 0.82,
      inputBarBg: inputBarBg,
      inputBarBorder: inputBarBorder,
      inputBarText: bubbleText,
    );
  }

  static BackgroundForegroundPalette _derivePalette(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    final blackContrast = _contrastRatio(Colors.black, dominant);
    final whiteContrast = _contrastRatio(Colors.white, dominant);
    final useLightForeground = whiteContrast >= blackContrast;
    final fallback = useLightForeground ? Colors.white : Colors.black;
    final primaryCandidate = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.22).clamp(0.04, 0.28),
      useLightForeground ? 0.96 : 0.08,
    ).toColor();
    final secondaryCandidate = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.30).clamp(0.05, 0.34),
      useLightForeground ? 0.88 : 0.16,
    ).toColor();
    final subtleCandidate = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 0.36).clamp(0.06, 0.38),
      useLightForeground ? 0.80 : 0.22,
    ).toColor();

    return BackgroundForegroundPalette(
      dominant: dominant,
      primary: _ensureContrast(
        primaryCandidate,
        dominant,
        fallback,
        minimum: 4.5,
      ),
      secondary: _ensureContrast(
        secondaryCandidate,
        dominant,
        fallback,
        minimum: 4.5,
      ),
      subtle: _ensureContrast(
        subtleCandidate,
        dominant,
        fallback,
        minimum: 3.0,
      ),
    );
  }

  static Color _ensureContrast(
    Color candidate,
    Color background,
    Color fallback, {
    required double minimum,
  }) {
    if (_contrastRatio(candidate, background) >= minimum) return candidate;
    for (var step = 1; step <= 10; step++) {
      final adjusted = Color.lerp(candidate, fallback, step / 10)!;
      if (_contrastRatio(adjusted, background) >= minimum) return adjusted;
    }
    return fallback;
  }

  static double _contrastRatio(Color a, Color b) {
    final aLuminance = a.computeLuminance();
    final bLuminance = b.computeLuminance();
    final lighter = aLuminance >= bLuminance ? aLuminance : bLuminance;
    final darker = aLuminance >= bLuminance ? bLuminance : aLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }
}

class _ColorBucket {
  int count = 0;
  int red = 0;
  int green = 0;
  int blue = 0;

  void add(int r, int g, int b) {
    count++;
    red += r;
    green += g;
    blue += b;
  }

  Color get color => Color.fromARGB(
    255,
    (red / count).round(),
    (green / count).round(),
    (blue / count).round(),
  );
}
