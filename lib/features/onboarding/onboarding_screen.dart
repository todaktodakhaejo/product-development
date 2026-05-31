import 'package:flutter/material.dart';

import '../../state/storage_scope.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';

/// ONB-01: 최초 진입 시 '기록이 아닌 해소' 컨셉과 사용 흐름 안내.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _OnbPage(
      emoji: '🫧',
      title: '기록이 아니라, 해소',
      body: '감정을 적어 남기는 앱이 아니에요.\n잠깐 꺼내 두고, 흘려보내는 곳이에요.',
    ),
    _OnbPage(
      emoji: '👆',
      title: '먼저 손으로 만져 보세요',
      body: '화면 속 공을 흔들고, 굴리고, 문질러 보세요.\n말로 옮기기 전에 감각으로 먼저 풀어요.',
    ),
    _OnbPage(
      emoji: '🔥',
      title: '꺼낸 마음을 흘려보내요',
      body: '떠오른 감정을 적고,\n태우거나 날려 보내며 의식처럼 해소해요.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    } else {
      _enter();
    }
  }

  void _enter() {
    // 온보딩을 끝냈다고 기록 → 다음 실행부터 홈으로 직행.
    StorageScope.of(context).setOnboardingDone();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _enter,
                  child: const Text('건너뛰기',
                      style: TextStyle(color: Colors.white54)),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: _pages,
                ),
              ),
              _Dots(count: _pages.length, index: _page),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.ballGlow,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(isLast ? '시작하기' : '다음'),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbPage extends StatelessWidget {
  const _OnbPage(
      {required this.emoji, required this.title, required this.body});
  final String emoji;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 84)),
          const SizedBox(height: 40),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w700, height: 1.3)),
          const SizedBox(height: 20),
          Text(body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, color: Colors.white70, height: 1.6)),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? AppColors.ballGlow : Colors.white24,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
