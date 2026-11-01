import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/character_display_name.dart';

void main() {
  test('character cards append a non-empty remark in parentheses', () {
    expect(
      characterCardDisplayName(<String, dynamic>{
        'name': '陸昭華',
        'remark': '小祖宗',
      }),
      '陸昭華（小祖宗）',
    );
  });

  test('character cards keep the original name without a remark', () {
    expect(
      characterCardDisplayName(<String, dynamic>{
        'name': '陸昭華',
        'remark': '   ',
      }),
      '陸昭華',
    );
  });
}
