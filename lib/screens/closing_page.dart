import 'dart:async';

import 'package:flutter/material.dart';

import '../models/ritual_phase.dart';
import '../services/haptics/haptics.dart';
import '../state/app_services.dart';
import '../state/ritual_scope.dart';
import '../theme/app_colors.dart';
import '../widgets/app_background.dart';
import '../widgets/blob_object.dart';

/// 마무리 — 다시 나에게 돌아온다 (PRODUCT_SPEC 4.5).
///
/// 3초간 빈 화면(여백·정적) → 오브제가 천천히 다시 등장 → 한 줄 메시지 →
/// [메인으로 돌아가기].
class ClosingPage extends StatefulWidget {
  const ClosingPage({super.key});

  @override
  State<ClosingPage> createState() => _ClosingPageState();
}

class _ClosingPageState extends State<ClosingPage> {
  Timer? _revealTimer;
  bool _revealed = false;
  String _message = '다 보냈어요';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final session = RitualScope.of(context);
      session.goTo(RitualPhase.closing);
      // 의식 종류에 따라 마무리 메시지 변주(간직 의식은 다른 카피).
      _message = session.ritualType?.closingMessage ?? '다 보냈어요';
    });
    _revealTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _revealed = true);
      // TODO(haptics): 등장 순간 아주 약한 여운 햅틱 + 정적 사운드.
      AppServicesScope.of(context).haptics.play(HapticPattern.tapPop);
    });
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    super.dispose();
  }

  void _backToMain() {
    RitualScope.of(context).reset();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 1200),
            curve: Curves.easeInOutCubic,
            opacity: _revealed ? 1 : 0,
            child: Column(
              children: [
                const Spacer(flex: 2),
                const BlobObject(size: 160),
                const SizedBox(height: 40),
                Text(_message, style: Theme.of(context).textTheme.titleLarge),
                const Spacer(flex: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 36),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.buttonPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 14,
                      ),
                    ),
                    onPressed: _backToMain,
                    child: const Text('메인으로 돌아가기'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
