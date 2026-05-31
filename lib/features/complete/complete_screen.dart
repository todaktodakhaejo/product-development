import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/strings.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';

/// 6단계 의식 후·완료. END-03 완료 멘트 + END-04 홈 리셋.
class CompleteScreen extends StatefulWidget {
  const CompleteScreen({super.key, required this.afterglow});

  /// 의식별 마무리 잔상(END-01). 예: 촛불, 종이더미, 후광 등.
  final Widget afterglow;

  @override
  State<CompleteScreen> createState() => _CompleteScreenState();
}

class _CompleteScreenState extends State<CompleteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Haptics.instance.fire(HapticLevel.success, throttle: false);
    });
  }

  void _backToHome() {
    SessionScope.of(context).reset(); // END-04
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              SizedBox(height: 180, child: Center(child: widget.afterglow)),
              const SizedBox(height: 40),
              const Text(
                kCompletionMessage,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                '잘 보냈어요. 마음이 조금 가벼워졌길.',
                style: TextStyle(color: Colors.white60),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 36),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _backToHome,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.ballGlow,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text('처음으로'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
