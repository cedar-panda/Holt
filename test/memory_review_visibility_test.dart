import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/memory_action_proposal.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/memory_review_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reply-focused review also includes on-device duplicate proposals', () {
    final reply = _proposal(id: 'reply', sourceMessageId: 42);
    final local = _proposal(id: 'local', existingDuplicateScan: true);
    final unrelated = _proposal(id: 'other', sourceMessageId: 99);

    expect(MemoryReviewTab.visibleInSourceReview(reply, 42), isTrue);
    expect(MemoryReviewTab.visibleInSourceReview(local, 42), isTrue);
    expect(MemoryReviewTab.visibleInSourceReview(unrelated, 42), isFalse);
  });

  test('clear confirmation word follows all three app languages', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    expect(MemoryReviewTab.clearConfirmationWord(), '刪除');
    await L.setLocale('zh_CN');
    expect(MemoryReviewTab.clearConfirmationWord(), '删除');
    await L.setLocale('en');
    expect(MemoryReviewTab.clearConfirmationWord(), 'DELETE');
  });
}

MemoryActionProposal _proposal({
  required String id,
  int? sourceMessageId,
  bool existingDuplicateScan = false,
}) {
  return MemoryActionProposal(
    id: id,
    characterId: 'char-a',
    mode: 'romance',
    action: MemoryActionProposal.actionMerge,
    source: existingDuplicateScan ? 'local_scan' : 'model',
    sourceConversationId: 'conv-a',
    sourceMessageId: sourceMessageId,
    targetIds: const [1, 2],
    payload: {'existing_duplicate_scan': existingDuplicateScan},
    baseVersions: const {},
    fingerprint: id,
    status: MemoryActionProposal.statusPending,
    createdAt: DateTime.utc(2026, 8, 7),
    seenAt: null,
    resolvedAt: null,
    error: '',
    result: const {},
  );
}
