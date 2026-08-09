import 'package:flutter/material.dart';

class CollapsibleOverview extends StatefulWidget {
  const CollapsibleOverview({super.key, required this.text, this.maxLines = 2});
  final String text;
  final int maxLines;

  @override
  State<CollapsibleOverview> createState() => _CollapsibleOverviewState();
}

class _CollapsibleOverviewState extends State<CollapsibleOverview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Text(
          widget.text,
          maxLines: _expanded ? null : widget.maxLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, height: 1.65, color: Color(0xFF4F4F4F)),
        ),
      ),
      Align(
        alignment: Alignment.center,
        child: ExcludeFocus(
          child: TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded),
            label: Text(_expanded ? '收起' : '查看更多'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ),
      ),
    ]);
  }
}
