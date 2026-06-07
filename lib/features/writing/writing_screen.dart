import 'package:flutter/material.dart';

import '../../core/ritual_audio.dart';
import '../../state/analytics_scope.dart';
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
  late SessionState _session;
  bool _restored = false;
  int _prevLen = 0; // 직전 글자 수(늘어날 때만 타이핑 효과음).

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.of(context);
    // 화면 진입 시 세션에 임시 보존된 초안을 한 번만 되살린다.
    if (!_restored) {
      _restored = true;
      _controller.text = _session.text;
      // 커서를 글 끝으로 두어 이어서 쓰기 편하게.
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      _prevLen = _controller.text.length; // 복원분엔 효과음 안 나게 기준 맞춤.
      AnalyticsScope.of(context).writingStarted(); // 글쓰기 화면 진입
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    _session.writeText(_controller.text);
    // 분석: 글 '내용'은 절대 전송 안 함 — 글자 수만(프라이버시 원칙).
    AnalyticsScope.of(context).writingCompleted(_controller.text.length);
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
      body: _FadeIn(
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '여기 적은 건 아무에게도 보이지 않아요.\n맞춤법도, 끝맺음도 신경 쓰지 마세요. 떠오르는 그대로면 돼요.',
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
                    autofocus: true,
                    onChanged: (v) {
                      // 글자가 늘어날 때만 타이핑 효과음(지우기엔 무음).
                      if (v.length > _prevLen) RitualAudio.instance.typeKey();
                      _prevLen = v.length;
                      // 입력할 때마다 세션에 초안 임시 보존(알림 없음).
                      // dispose에서 저장하면 의식 완료 reset 직후 다시 덮어써져
                      // 초기화가 안 되므로, 저장 시점을 입력으로 옮긴다.
                      _session.saveDraft(v);
                      setState(() {});
                    },
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
                child: const Text('이 마음 보내기'),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 화면 진입 시 한 번 부드럽게 떠오르게 하는 페이드인 래퍼.
class _FadeIn extends StatefulWidget {
  const _FadeIn({required this.child});
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> {
  double _opacity = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      child: widget.child,
    );
  }
}
