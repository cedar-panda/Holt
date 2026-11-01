class BackgroundPreset {
  static const Object _unchanged = Object();

  final int slot;
  final String homePath;
  final double homeScale;
  final double homeOffsetX;
  final double homeOffsetY;
  final double homeBlur;
  final String chatPath;
  final double chatScale;
  final double chatOffsetX;
  final double chatOffsetY;
  final double chatBlur;
  final int? chatAiBubbleColor;
  final int? chatUserBubbleColor;
  final int? chatBubbleTextColor;
  final int? chatThinkingTextColor;
  final double? chatBubbleOpacity;
  /// Which custom image is reused on the call screen: none/home/chat.
  final String callBackgroundScope;

  const BackgroundPreset({
    required this.slot,
    this.homePath = '',
    this.homeScale = 1.0,
    this.homeOffsetX = 0.0,
    this.homeOffsetY = 0.0,
    this.homeBlur = 0.0,
    this.chatPath = '',
    this.chatScale = 1.0,
    this.chatOffsetX = 0.0,
    this.chatOffsetY = 0.0,
    this.chatBlur = 0.0,
    this.chatAiBubbleColor,
    this.chatUserBubbleColor,
    this.chatBubbleTextColor,
    this.chatThinkingTextColor,
    this.chatBubbleOpacity,
    this.callBackgroundScope = 'none',
  });

  bool get hasHomeImage => homePath.trim().isNotEmpty;
  bool get hasChatImage => chatPath.trim().isNotEmpty;
  bool get isEmpty => !hasHomeImage && !hasChatImage;

  BackgroundPreset copyWith({
    int? slot,
    String? homePath,
    double? homeScale,
    double? homeOffsetX,
    double? homeOffsetY,
    double? homeBlur,
    String? chatPath,
    double? chatScale,
    double? chatOffsetX,
    double? chatOffsetY,
    double? chatBlur,
    Object? chatAiBubbleColor = _unchanged,
    Object? chatUserBubbleColor = _unchanged,
    Object? chatBubbleTextColor = _unchanged,
    Object? chatThinkingTextColor = _unchanged,
    Object? chatBubbleOpacity = _unchanged,
    String? callBackgroundScope,
  }) {
    return BackgroundPreset(
      slot: slot ?? this.slot,
      homePath: homePath ?? this.homePath,
      homeScale: homeScale ?? this.homeScale,
      homeOffsetX: homeOffsetX ?? this.homeOffsetX,
      homeOffsetY: homeOffsetY ?? this.homeOffsetY,
      homeBlur: homeBlur ?? this.homeBlur,
      chatPath: chatPath ?? this.chatPath,
      chatScale: chatScale ?? this.chatScale,
      chatOffsetX: chatOffsetX ?? this.chatOffsetX,
      chatOffsetY: chatOffsetY ?? this.chatOffsetY,
      chatBlur: chatBlur ?? this.chatBlur,
      chatAiBubbleColor: identical(chatAiBubbleColor, _unchanged)
          ? this.chatAiBubbleColor
          : chatAiBubbleColor as int?,
      chatUserBubbleColor: identical(chatUserBubbleColor, _unchanged)
          ? this.chatUserBubbleColor
          : chatUserBubbleColor as int?,
      chatBubbleTextColor: identical(chatBubbleTextColor, _unchanged)
          ? this.chatBubbleTextColor
          : chatBubbleTextColor as int?,
      chatThinkingTextColor: identical(chatThinkingTextColor, _unchanged)
          ? this.chatThinkingTextColor
          : chatThinkingTextColor as int?,
      chatBubbleOpacity: identical(chatBubbleOpacity, _unchanged)
          ? this.chatBubbleOpacity
          : chatBubbleOpacity as double?,
      callBackgroundScope: callBackgroundScope ?? this.callBackgroundScope,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'slot': slot,
    'home_path': homePath,
    'home_scale': homeScale,
    'home_offset_x': homeOffsetX,
    'home_offset_y': homeOffsetY,
    'home_blur': homeBlur,
    'chat_path': chatPath,
    'chat_scale': chatScale,
    'chat_offset_x': chatOffsetX,
    'chat_offset_y': chatOffsetY,
    'chat_blur': chatBlur,
    'chat_ai_bubble_color': chatAiBubbleColor,
    'chat_user_bubble_color': chatUserBubbleColor,
    'chat_bubble_text_color': chatBubbleTextColor,
    'chat_thinking_text_color': chatThinkingTextColor,
    'chat_bubble_opacity': chatBubbleOpacity,
    'call_background_scope': callBackgroundScope,
  };

  factory BackgroundPreset.fromJson(
    Map<String, dynamic> json, {
    required int fallbackSlot,
  }) {
    double number(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    int? optionalInt(String key) => (json[key] as num?)?.toInt();

    return BackgroundPreset(
      slot: (json['slot'] as num?)?.toInt() ?? fallbackSlot,
      homePath: json['home_path']?.toString() ?? '',
      homeScale: number('home_scale', 1.0).clamp(0.8, 2.0),
      homeOffsetX: number('home_offset_x', 0.0).clamp(-0.5, 0.5),
      homeOffsetY: number('home_offset_y', 0.0).clamp(-0.5, 0.5),
      homeBlur: number('home_blur', 0.0).clamp(0.0, 20.0),
      chatPath: json['chat_path']?.toString() ?? '',
      chatScale: number('chat_scale', 1.0).clamp(0.8, 2.0),
      chatOffsetX: number('chat_offset_x', 0.0).clamp(-0.5, 0.5),
      chatOffsetY: number('chat_offset_y', 0.0).clamp(-0.5, 0.5),
      chatBlur: number('chat_blur', 0.0).clamp(0.0, 20.0),
      chatAiBubbleColor: optionalInt('chat_ai_bubble_color'),
      chatUserBubbleColor: optionalInt('chat_user_bubble_color'),
      chatBubbleTextColor: optionalInt('chat_bubble_text_color'),
      chatThinkingTextColor: optionalInt('chat_thinking_text_color'),
      chatBubbleOpacity: (json['chat_bubble_opacity'] as num?)
          ?.toDouble()
          .clamp(0.15, 1.0),
      callBackgroundScope: switch (
        json['call_background_scope']?.toString()
      ) {
        'home' => 'home',
        'chat' => 'chat',
        _ => 'none',
      },
    );
  }
}
