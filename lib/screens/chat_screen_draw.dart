// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatDrawMethods on _ChatScreenState {
  Future<void> _runDrawAsync(
    int messageId,
    String prompt,
    String baseLog,
    String characterId,
  ) async {
    final generationEpoch = ++_imageGenerationEpoch;
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
    if (generationEpoch != _imageGenerationEpoch) {
      if (path != null) {
        final generatedFile = File(path);
        if (await generatedFile.exists()) {
          await generatedFile.delete().catchError((_) => generatedFile);
        }
      }
      final cancelledLog = baseLog.contains('🎨 生成中…')
          ? baseLog.replaceFirst('🎨 生成中…', '🎨 已取消')
          : baseLog;
      await DatabaseHelper.updateMessageDraw(messageId, null, cancelledLog);
      return;
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

  Future<void> _cancelActiveImageGeneration() async {
    _imageGenerationEpoch++;
    final pending = _messages
        .where((message) => message.imagePath == 'generating')
        .toList(growable: false);
    if (mounted) {
      _refreshChatState(() {
        _isGeneratingImage = false;
        for (final pendingMessage in pending) {
          final index = _messages.indexWhere(
            (message) => message.id == pendingMessage.id,
          );
          if (index < 0) continue;
          final memoryLog = pendingMessage.memoryLog.replaceFirst(
            '🎨 生成中…',
            '🎨 已取消',
          );
          _messages[index] = Message(
            id: pendingMessage.id,
            conversationId: pendingMessage.conversationId,
            characterId: pendingMessage.characterId,
            text: pendingMessage.text,
            isUser: pendingMessage.isUser,
            imagePath: null,
            imagePaths: pendingMessage.imagePaths,
            splitMode: pendingMessage.splitMode,
            cacheHit: pendingMessage.cacheHit,
            status: pendingMessage.status,
            memoryLog: memoryLog,
            webSearchTrace: pendingMessage.webSearchTrace,
            emailDraft: pendingMessage.emailDraft,
            personaCard: pendingMessage.personaCard,
            createdAt: pendingMessage.createdAt,
          );
        }
      });
    }
    for (final pendingMessage in pending) {
      final id = pendingMessage.id;
      if (id == null) continue;
      await DatabaseHelper.updateMessageDraw(
        id,
        null,
        pendingMessage.memoryLog.replaceFirst('🎨 生成中…', '🎨 已取消'),
      );
    }
  }
}
