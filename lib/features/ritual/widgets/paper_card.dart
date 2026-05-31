import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 작성한 감정 글이 적힌 종이. 의식 연출의 대상 오브제.
class PaperCard extends StatelessWidget {
  const PaperCard({super.key, required this.text, this.width, this.height});

  final String text;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      child: Text(
        text.isEmpty ? '…' : text,
        style: const TextStyle(color: AppColors.ink, fontSize: 15, height: 1.6),
        overflow: TextOverflow.fade,
      ),
    );
  }
}
