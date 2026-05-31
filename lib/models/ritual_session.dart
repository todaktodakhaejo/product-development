import 'package:flutter/foundation.dart';

import 'ritual_phase.dart';
import 'ritual_type.dart';

/// 한 번의 의식(Soothe→Pour→Release→Closing) 동안의 세션 상태.
///
/// 화면 간 데이터 전달은 이 단일 모델로 통일한다. 화면은 [RitualScope]로 꺼내
/// 읽고, 변경 시 [notifyListeners]로 갱신된다.
///
/// 제품 철학: 글 내용([memoText])은 의식이 끝나면 [reset]에서 비운다(영구 저장 X).
class RitualSession extends ChangeNotifier {
  String _memoText = '';
  RitualType? _ritualType;
  RitualPhase _phase = RitualPhase.soothe;

  String get memoText => _memoText;
  RitualType? get ritualType => _ritualType;
  RitualPhase get phase => _phase;

  /// 글쓰기 단계에서 메모 갱신.
  void updateMemo(String text) {
    _memoText = text;
    notifyListeners();
  }

  /// 해소 의식 선택.
  void chooseRitual(RitualType type) {
    _ritualType = type;
    notifyListeners();
  }

  /// 단계 전환 (네비게이션과 함께 호출, 상태 표시용).
  void goTo(RitualPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// 의식 완료 후 세션 초기화. 글 내용은 남기지 않는다.
  void reset() {
    _memoText = '';
    _ritualType = null;
    _phase = RitualPhase.soothe;
    notifyListeners();
  }
}
