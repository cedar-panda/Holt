import 'package:flutter/material.dart';

/// Owns a small set of text controllers for a dialog or bottom sheet.
///
/// Keeping the controllers inside the route subtree means they are disposed
/// only after the route's exit animation has finished. This avoids both leaked
/// controllers and `used after being disposed` failures during dismissal.
class ManagedTextControllers extends StatefulWidget {
  const ManagedTextControllers({
    super.key,
    required this.initialValues,
    required this.builder,
  });

  final List<String> initialValues;
  final Widget Function(
    BuildContext context,
    List<TextEditingController> controllers,
  )
  builder;

  @override
  State<ManagedTextControllers> createState() => _ManagedTextControllersState();
}

class _ManagedTextControllersState extends State<ManagedTextControllers> {
  late final List<TextEditingController> _controllers = widget.initialValues
      .map((value) => TextEditingController(text: value))
      .toList(growable: false);

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controllers);
}
