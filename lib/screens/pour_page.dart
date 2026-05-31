import 'dart:async';

import 'package:flutter/material.dart';

import '../models/ritual_phase.dart';
import '../models/ritual_type.dart';
import '../routing/route_transitions.dart';
import '../state/ritual_scope.dart';
import '../theme/app_colors.dart';
import '../widgets/app_background.dart';
import '../widgets/ritual_sheet.dart';
import 'release_ritual_page.dart';

/// 분출 단계 — 종이에 마음을 쏟아낸다 (PRODUCT_SPEC 4.3).
///
/// 입력을 멈추고 3초간 정지하면 하단에서 해소 의식 선택 시트가 떠오른다(강요 X).
class PourPage extends StatefulWidget {
  const PourPage({super.key});

  @override
  State<PourPage> createState() => _PourPageState();
}

class _PourPageState extends State<PourPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _idleTimer;
  bool _sheetOpen = false;

  static const Duration _idleDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) RitualScope.of(context).goTo(RitualPhase.pour);
    });
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    RitualScope.of(context).updateMemo(_controller.text);
    // TODO(haptics): 타이핑마다 selection-tick급 햅틱 + 종이 미세 떨림.
    _restartIdleTimer();
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    if (_controller.text.trim().isEmpty) return;
    _idleTimer = Timer(_idleDelay, _showRitualSheet);
  }

  Future<void> _showRitualSheet() async {
    if (!mounted || _sheetOpen) return;
    setState(() => _sheetOpen = true);
    RitualScope.of(context).goTo(RitualPhase.releaseSelect);

    final selected = await showRitualSheet(context);
    if (!mounted) return;
    setState(() => _sheetOpen = false);

    if (selected == null) {
      // 시트를 닫고 계속 쓰면 다시 타이머가 돈다(강요 X).
      RitualScope.of(context).goTo(RitualPhase.pour);
      _restartIdleTimer();
      return;
    }
    _goToRitual(selected);
  }

  void _goToRitual(RitualType type) {
    final session = RitualScope.of(context);
    session.chooseRitual(type);
    session.goTo(RitualPhase.releaseRitual);
    Navigator.of(context).push(fadeRoute(const ReleaseRitualPage()));
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '마음속 이야기를 종이에 쏟아내요',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                // 크림색 종이 — 글이 길어지면 스크롤로 늘어남.
                // TODO(motion): "무한 두루마리"처럼 종이가 아래로 늘어나는 연출.
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.paper,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.paperLine.withValues(alpha: 0.5),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      cursorColor: AppColors.textPrimary,
                      style: Theme.of(context).textTheme.bodyLarge,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: '떠오르는 대로 적어보세요',
                        hintStyle: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '잠시 멈추면 해소할 방법을 보여드릴게요',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
