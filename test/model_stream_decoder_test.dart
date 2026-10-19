import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/model_stream_decoder.dart';

void main() {
  test('never emits a chunk-split XML action', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('正文完成\n\n<me'), '正文完成');
    expect(decoder.add('mo>[關係] 隱藏內容'), '');
    expect(decoder.add('</memo>'), '');
    expect(decoder.close(), '');
  });

  test('keeps ordinary angle-bracket prose', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('比較 1 < 2，'), '比較 1 < 2，');
    expect(decoder.add('<em>文字</em>'), '<em>文字</em>');
    expect(decoder.close(), '');
  });

  test('hides standalone actions without swallowing following prose', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('前面<transfer amount="3"/>後面'), '前面後面');
    expect(decoder.close(), '');
  });

  test('hides legacy call control actions', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('接通前<decline_'), '接通前');
    expect(decoder.add('call/>掛斷後<hangup/>尾句'), '掛斷後尾句');
    expect(decoder.close(), '');
  });

  test('never emits a chunk-split call opening action', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('正文<ca'), '正文');
    expect(decoder.add('ll>這是通話內部開場白</ca'), '');
    expect(decoder.add('ll>尾句'), '尾句');
    expect(decoder.close(), '');
  });

  test('hides JSON action envelope split across chunks', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('回答\n[[HOLT_'), '回答');
    expect(decoder.add('ACTIONS]]{"actions":[{"type":"memory.propose"}]}'), '');
    expect(decoder.add('[[/HOLT_ACTIONS]]'), '');
    expect(decoder.close(), '');
  });

  test('hides chunk-split thinking blocks from visible prose', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('<thi'), '');
    expect(decoder.add('nking>private reasoning</thinking>正文'), '正文');
    expect(decoder.close(), '');
  });

  test('fails closed for an unfinished hidden action', () {
    final decoder = ModelStreamDecoder();

    expect(decoder.add('可見<memo>不能顯示'), '可見');
    expect(decoder.close(), '');
  });
}
