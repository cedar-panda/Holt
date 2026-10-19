import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/screens/sticker_library_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/sticker_service.dart';

void main() {
  test('user and character sticker libraries have distinct titles', () {
    final userTitle = stickerLibraryTitle(
      characterId: StickerService.userBucket,
    );
    final characterTitle = stickerLibraryTitle(
      characterId: 'character-1',
      characterName: '顧遠',
    );
    final personaTitle = stickerLibraryTitle(
      characterId: StickerService.userBucketForPersona('persona-1'),
    );

    expect(userTitle, L.get('me_sticker'));
    expect(personaTitle, L.get('me_sticker'));
    expect(characterTitle, contains('顧遠'));
    expect(characterTitle, isNot(userTitle));
  });

  test('missing character name never falls back to the user title', () {
    expect(
      stickerLibraryTitle(characterId: 'missing-character'),
      isNot(L.get('me_sticker')),
    );
  });
}
