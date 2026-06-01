import 'package:flutter/material.dart';

import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../ritual/ritual_select_screen.dart';

/// 4단계 감정 글쓰기. 아무에게도 보이지 않는, 형식 부담 없는 입력.
class WritingScreen extends StatefulWidget {
  const WritingScreen({super.key});

  @override
  State<WritingScreen> createState() => _WritingScreenState();
}

class _WritingScreenState extends State<WritingScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    final session = SessionScope.of(context);
    session.writeText(_controller.text);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RitualSelectScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canProceed = _controller.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.paper,
        foregroundColor: AppColors.ink,
        elevation: 0,
        title: const Text('마음 꺼내기',
            style: TextStyle(color: AppColors.ink, fontSize: 16)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '여기 적은 건 누구에게도 보이지 않아요.\n맞춤법도, 완성도 신경 쓰지 말고 마구 적어 보세요.',
                style: TextStyle(color: Colors.black54, height: 1.5),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: AppColors.paperShadow,
                        blurRadius: 12,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: TextField(
                    controller: _controller,
                    onChanged: (_) => setState(() {}),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    cursorColor: AppColors.ink,
                    style: const TextStyle(
                        color: AppColors.ink, fontSize: 17, height: 1.7),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '지금 마음에 떠오르는 것들…',
                      hintStyle: TextStyle(color: Colors.black26),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canProceed ? _next : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ink,
                  foregroundColor: AppColors.paper,
                  disabledBackgroundColor: Colors.black12,
                  disabledForegroundColor: Colors.black26,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text('흘려보내기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
