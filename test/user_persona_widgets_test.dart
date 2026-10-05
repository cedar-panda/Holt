import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/user_persona_service.dart';
import 'package:project_yanci/widgets/user_persona_avatar_pair.dart';
import 'package:project_yanci/widgets/persona_carousel.dart';
import 'package:project_yanci/widgets/user_persona_switcher.dart';

void main() {
  final now = DateTime(2026, 9, 14);

  List<UserPersona> roles(int count) => List<UserPersona>.generate(
    count,
    (index) => UserPersona(
      id: 'role-$index',
      displayName: 'Role $index',
      createdAt: now,
      updatedAt: now,
    ),
  );

  testWidgets('one role exposes the carousel and create slot', (tester) async {
    final personas = roles(1);
    var createCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaSwitcher(
            personas: personas,
            selectedId: personas.single.id,
            onSelected: (_) {},
            onOpenProfile: () {},
            onCreate: () => createCount++,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('persona-carousel-toggle')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('persona-carousel-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('persona-create-slot')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('persona-create-slot')));
    expect(createCount, 1);
  });

  testWidgets('two roles expose carousel and view-all drawer', (tester) async {
    final personas = roles(2);
    var selected = personas.first;
    var profileOpenCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SingleChildScrollView(
              child: UserPersonaSwitcher(
                personas: personas,
                selectedId: selected.id,
                onSelected: (value) => setState(() => selected = value),
                onOpenProfile: () => profileOpenCount++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('persona-carousel-toggle')));
    await tester.pumpAndSettle();
    expect(profileOpenCount, 0);
    expect(find.byType(PersonaCarousel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('persona-view-all-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('persona-view-all-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('persona-all-drawer')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('persona-all-item-role-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('persona-all-item-role-1')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('persona-star-role-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('persona-all-item-role-1')));
    await tester.pumpAndSettle();
    expect(selected.id, 'role-1');
  });

  testWidgets('avatar pair exposes a dashed binding target when unbound', (
    tester,
  ) async {
    final persona = roles(1).single;
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaAvatarPair(
            persona: persona,
            onBindingTap: () => tapped = true,
          ),
        ),
      ),
    );

    final binding = find.byKey(const ValueKey('persona-bind-character-button'));
    expect(binding, findsOneWidget);
    await tester.tap(binding);
    expect(tapped, isTrue);
  });

  testWidgets('carousel exposes its page surface for multiple roles', (
    tester,
  ) async {
    final personas = roles(6);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserPersonaSwitcher(
              personas: personas,
              selectedId: personas[3].id,
              onSelected: (_) {},
              onOpenProfile: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('persona-carousel-toggle')));
    await tester.pumpAndSettle();
    final carousel = find.byKey(const ValueKey('persona-carousel'));
    final selected = find.byKey(const ValueKey('persona-carousel-slot-role-3'));
    expect(carousel, findsOneWidget);
    expect(selected, findsOneWidget);
    expect(
      tester.getCenter(selected).dx,
      closeTo(tester.getCenter(carousel).dx, .5),
    );
    final viewAll = tester.widget<Text>(find.text('View all'));
    expect(viewAll.style?.color?.a, closeTo(.50, .01));
  });

  testWidgets('avatar pair can hide the unbound companion target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaAvatarPair(
            persona: roles(1).single,
            showAddWhenUnbound: false,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('persona-bind-character-button')),
      findsNothing,
    );
    final frame = tester.widget<Container>(
      find.byKey(const ValueKey('persona-brush-frame')),
    );
    final decoration = frame.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.border!.top.width, 1.5);
    final frameRect = tester.getRect(
      find.byKey(const ValueKey('persona-brush-frame')),
    );
    final overscanRect = tester.getRect(
      find.byKey(const ValueKey('persona-brush-overscan-canvas')),
    );
    expect(overscanRect.top, lessThan(frameRect.top));
    expect(overscanRect.bottom, greaterThan(frameRect.bottom));
    expect(overscanRect.left, lessThan(frameRect.left));
    expect(overscanRect.right, greaterThan(frameRect.right));
  });

  testWidgets('empty identity avatar invokes creation', (tester) async {
    var createCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaCreateAvatar(onTap: () => createCount++),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('persona-bind-character-button')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('persona-create-avatar-button')),
    );
    expect(createCount, 1);
  });

  testWidgets('name can be hidden without removing carousel access', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaSwitcher(
            personas: roles(2),
            selectedId: 'role-0',
            onSelected: (_) {},
            onOpenProfile: () {},
            hideName: true,
          ),
        ),
      ),
    );

    expect(find.text('Role 0'), findsNothing);
    expect(
      find.byKey(const ValueKey('persona-carousel-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('persona-previous-button')), findsNothing);
    expect(find.byKey(const ValueKey('persona-next-button')), findsNothing);
  });

  testWidgets('bound avatar pair accepts a label on its red connection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserPersonaAvatarPair(
            persona: roles(1).single,
            companion: const <String, dynamic>{
              'id': 'char-a',
              'name': 'Character A',
              'avatar_path': '',
            },
            connectionLabel: const Text('第 15 天'),
          ),
        ),
      ),
    );

    expect(find.text('第 15 天'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bound-character-avatar-char-a')),
      findsOneWidget,
    );
  });

  testWidgets('switching persona never carries the previous companion', (
    tester,
  ) async {
    final personas = roles(2);
    var persona = personas.first;
    Map<String, dynamic>? companion = const <String, dynamic>{
      'id': 'char-b',
      'name': 'Character B',
      'avatar_path': '',
    };
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: UserPersonaAvatarPair(
                persona: persona,
                companion: companion,
                showAddWhenUnbound: false,
              ),
            );
          },
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('bound-character-avatar-char-b')),
      findsOneWidget,
    );
    update(() {
      persona = personas.last;
      companion = null;
    });
    await tester.pump();
    expect(
      find.byKey(const ValueKey('bound-character-avatar-char-b')),
      findsNothing,
    );
  });
}
