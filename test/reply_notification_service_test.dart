import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/reply_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
  });

  test('uses remark first and falls back to character name', () {
    final remarked = ReplyNotificationService.buildPayload(
      character: const <String, dynamic>{
        'id': 'char-1',
        'name': '顧遠',
        'remark': '遠哥',
      },
      reply: '好了。',
      conversationId: 'window-1',
    );
    final named = ReplyNotificationService.buildPayload(
      character: const <String, dynamic>{'id': 'char-1', 'name': '顧遠'},
      reply: '好了。',
      conversationId: 'window-1',
    );

    expect(remarked.title, '遠哥');
    expect(remarked.placeholder, '遠哥回覆你了');
    expect(named.title, '顧遠');
  });

  test('strips protocol blocks and inline functional markers', () {
    final payload = ReplyNotificationService.buildPayload(
      character: const <String, dynamic>{'id': 'char-1', 'name': '顧遠'},
      reply:
          '<think>內部推理</think>正文 [sticker:3] '
          '<memo>[偏好] 不應外露 @測試</memo> [transfer:8]',
      conversationId: 'window-1',
    );

    expect(payload.body, '正文');
  });

  test('truncates by visible characters and appends one ellipsis', () {
    final payload = ReplyNotificationService.buildPayload(
      character: const <String, dynamic>{'id': 'char-1', 'name': '顧遠'},
      reply: List<String>.filled(121, '字').join(),
      conversationId: 'window-1',
    );

    expect(payload.body.runes.length, 121);
    expect(payload.body.endsWith('…'), isTrue);
  });

  test('uses a neutral sticker fallback when no visible prose remains', () {
    final payload = ReplyNotificationService.buildPayload(
      character: const <String, dynamic>{'id': 'char-1', 'name': '顧遠'},
      reply: '[sticker:9]<memo>內部資料</memo>',
      conversationId: 'window-1',
    );

    expect(payload.body, '傳了一張貼圖');
  });
}
