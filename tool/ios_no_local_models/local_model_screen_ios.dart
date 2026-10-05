import 'package:flutter/material.dart';

import 'package:project_yanci/services/locale_strings.dart';

class LocalModelScreen extends StatelessWidget {
  const LocalModelScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: Text(
        L.pick(
          en: 'On-device models are unavailable on iOS.',
          zhTW: 'iOS 不提供本機模型。',
          zhCN: 'iOS 不提供本地模型。',
        ),
      ),
    ),
  );
}
