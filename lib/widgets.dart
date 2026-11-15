import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// エラー表示。「コピー」ボタンで全文をコピーできる（長押しで一部だけ選ぶこともできる）
class ErrorBox extends StatelessWidget {
  final String text;
  final Color color;
  const ErrorBox(this.text, {super.key, this.color = Colors.redAccent});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(text, style: TextStyle(color: color)),
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('コピーしました'), duration: Duration(seconds: 2)));
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('エラーをコピー'),
          ),
        ]),
      );
}
