import 'package:flutter/material.dart';

import '../models/ritual_phase.dart';
import '../models/ritual_type.dart';
import '../routing/route_transitions.dart';
import '../state/ritual_scope.dart';
import '../widgets/app_background.dart';
import '../widgets/rituals/ritual_interactions.dart';
import 'closing_page.dart';

/// 해소 단계 — 선택한 의식을 수행한다 (PRODUCT_SPEC 4.4).
///
/// 세션의 [RitualType]에 맞는 전용 인터랙션 위젯을 띄우고, 완료되면 마무리로.
class ReleaseRitualPage extends StatefulWidget {
  const ReleaseRitualPage({super.key});

  @override
  State<ReleaseRitualPage> createState() => _ReleaseRitualPageState();
}

class _ReleaseRitualPageState extends State<ReleaseRitualPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) RitualScope.of(context).goTo(RitualPhase.releaseRitual);
    });
  }

  void _onComplete() {
    final session = RitualScope.of(context);
    session.goTo(RitualPhase.closing);
    Navigator.of(context).pushReplacement(fadeRoute(const ClosingPage()));
  }

  @override
  Widget build(BuildContext context) {
    final RitualType? type = RitualScope.of(context).ritualType;

    // 방어: 의식이 선택되지 않았으면 안내만 보여준다.
    if (type == null) {
      return Scaffold(
        body: AppBackground(
          child: Center(
            child: Text(
              '선택된 의식이 없어요',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: buildRitualInteraction(type, onComplete: _onComplete),
        ),
      ),
    );
  }
}
