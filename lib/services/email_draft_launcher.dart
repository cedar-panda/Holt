import 'package:url_launcher/url_launcher.dart';

import '../models/email_draft.dart';

class EmailDraftLauncher {
  const EmailDraftLauncher._();

  static Uri buildUri(EmailDraft draft) {
    final query =
        <String, String>{
              if (draft.subject.isNotEmpty) 'subject': draft.subject,
              if (draft.body.isNotEmpty) 'body': draft.body,
            }.entries
            .map(
              (entry) =>
                  '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}',
            )
            .join('&');
    return Uri(
      scheme: 'mailto',
      path: draft.to,
      // `queryParameters` follows HTML form encoding and turns spaces into
      // `+`. Some Gmail compose intents preserve those plus signs literally,
      // so mailto values use RFC-style percent encoding instead.
      query: query.isEmpty ? null : query,
    );
  }

  static Future<bool> open(EmailDraft draft) async {
    final uri = buildUri(draft);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
