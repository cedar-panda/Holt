import 'package:url_launcher/url_launcher.dart';

import '../models/email_draft.dart';

class EmailDraftLauncher {
  const EmailDraftLauncher._();

  static Uri buildUri(EmailDraft draft) {
    return Uri(
      scheme: 'mailto',
      path: draft.to,
      queryParameters: <String, String>{
        if (draft.subject.isNotEmpty) 'subject': draft.subject,
        if (draft.body.isNotEmpty) 'body': draft.body,
      },
    );
  }

  static Future<bool> open(EmailDraft draft) async {
    final uri = buildUri(draft);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
