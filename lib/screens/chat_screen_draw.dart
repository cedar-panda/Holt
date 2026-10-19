// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatDrawMethods on _ChatScreenState {
  Future<void> _runDrawAsync(
    int messageId,
    String prompt,
    String baseLog,
    String characterId,
  ) async {
    if (mounted) {
      _refreshChatState(() {
        _isGeneratingImage = true;
        final idx = _messages.indexWhere((m) => m.id == messageId);
        if (idx >= 0) {
          final m = _messages[idx];
          _messages[idx] = Message(
            id: m.id,
            conversationId: m.conversationId,
            characterId: m.characterId,
            text: m.text,
            isUser: false,
            imagePath: 'generating',
            imagePaths: m.imagePaths,
            splitMode: m.splitMode,
            cacheHit: m.cacheHit,
            status: m.status,
            memoryLog: m.memoryLog,
            webSearchTrace: m.webSearchTrace,
            emailDraft: m.emailDraft,
            personaCard: m.personaCard,
            createdAt: m.createdAt,
          );
        }
      });
    }
    String note;
    String? path;
    try {
      // 讀取角色卡綁定的畫畫錨點
      final anchors = await DatabaseHelper.getDrawAnchors(_activeCharacterId);
      path = await ImageGenService.generate(
        prompt,
        userAnchor: anchors.user,
        charAnchor: anchors.char,
        style: anchors.style,
        characterId: characterId,
        conversationId: widget.conversationId,
      );
      note = '🎨 生成圖片 ✓';
    } catch (e) {
      await AppErrorLogService.record(
        error: e,
        trigger: 'functional_image_model_request',
        source: 'functional_model',
        provider: await ApiSettings.getImageGenProvider(),
        model: await ApiSettings.getImageGenModel(),
      );
      final msg = e.toString();
      note = '🎨 畫圖失敗：${msg.length > 140 ? msg.substring(0, 140) : msg}';
    }
    final newLog = baseLog.contains('🎨 生成中…')
        ? baseLog.replaceFirst('🎨 生成中…', note)
        : baseLog;
    await DatabaseHelper.updateMessageDraw(messageId, path, newLog);
    if (!mounted) return;
    _refreshChatState(() {
      _isGeneratingImage = false;
      final idx = _messages.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        final m = _messages[idx];
        _messages[idx] = Message(
          id: m.id,
          conversationId: m.conversationId,
          characterId: m.characterId,
          text: m.text,
          isUser: false,
          imagePath: path ?? m.imagePath,
          imagePaths: m.imagePaths,
          splitMode: m.splitMode,
          cacheHit: m.cacheHit,
          status: m.status,
          memoryLog: newLog,
          webSearchTrace: m.webSearchTrace,
          emailDraft: m.emailDraft,
          personaCard: m.personaCard,
          createdAt: m.createdAt,
        );
      }
    });
  }
}
