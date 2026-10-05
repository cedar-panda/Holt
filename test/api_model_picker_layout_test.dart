import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/api_model_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('model controls keep search and explicit load on the main page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final controller = TextEditingController();
    var fetchCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiModelPicker(
            searchController: controller,
            isFetchingModels: false,
            onFilter: (_) {},
            onSelectModel: (_) {},
            onLoadModels: () => fetchCount++,
          ),
        ),
      ),
    );

    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      '搜尋或輸入模型 ID',
    );
    expect(find.text('載入'), findsOneWidget);
    expect(
      find.byKey(const Key('api_settings_model_refresh_button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('api_settings_model_refresh_button')),
    );
    expect(fetchCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
