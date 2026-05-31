import 'package:flutter/material.dart';

import '../models/ritual_phase.dart';
import '../routing/route_transitions.dart';
import '../services/haptics/haptics.dart';
import '../state/app_services.dart';
import '../state/ritual_scope.dart';
import '../widgets/app_background.dart';
import '../widgets/blob_object.dart';
import 'pour_page.dart';

/// 진정 단계 — 살아있는 오브제와 교감 (PRODUCT_SPEC 4.1 / 4.2).
class SoothePage extends StatefulWidget {
  const SoothePage({super.key});

  @override
  State<SoothePage> createState() => _SoothePageState();
}

class _SoothePageState extends State<SoothePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) RitualScope.of(context).goTo(RitualPhase.soothe);
    });
  }

  void _openPour() {
    final session = RitualScope.of(context);
    session.goTo(RitualPhase.pour);
    // TODO(motion): 오브제→종이 morph 전환으로 고도화.
    Navigator.of(context).push(fadeRoute(const PourPage()));
  }

  @override
  Widget build(BuildContext context) {
    final haptics = AppServicesScope.of(context).haptics;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  '살아있는 오브제와 교감하며\n감정을 진정시켜요',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 48),
              BlobObject(
                onTap: () => haptics.play(HapticPattern.tapPop),
                onOpen: _openPour,
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Text(
                  '오브제를 길게 누르면 마음을 적을 수 있어요',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
