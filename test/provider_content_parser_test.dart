import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/provider_content_parser.dart';

void main() {
  test('keeps plain provider content', () {
    expect(ProviderContentParser.visibleText('hello'), 'hello');
  });

  test('joins visible text blocks and ignores reasoning blocks', () {
    expect(
      ProviderContentParser.visibleText(<Object?>[
        <String, Object?>{'type': 'thinking', 'thinking': 'hidden'},
        <String, Object?>{'type': 'text', 'text': 'first'},
        <String, Object?>{'type': 'text', 'text': 'second'},
      ]),
      'firstsecond',
    );
  });

  test('handles nested content blocks used by compatible routers', () {
    expect(
      ProviderContentParser.visibleText(<String, Object?>{
        'content': <Object?>[
          <String, Object?>{'text': '正文'},
        ],
      }),
      '正文',
    );
  });
}
