import 'package:flutter/widgets.dart';

/// 5단계 의식(분출/보관). 이번 범위는 우선순위 '필수' 4종.
enum Ritual {
  burn('태우기', '불꽃에 실어 위로 흘려보내요', RitualKind.release),
  shredder('파쇄기', '잘게 부숴 폭죽처럼 날려요', RitualKind.release),
  paperPlane('종이비행기', '접어서 멀리 날려 보내요', RitualKind.release),
  jewelryBox('보석함 보관', '소중히 간직해 안치해요', RitualKind.keep);

  const Ritual(this.label, this.tagline, this.kind);
  final String label;
  final String tagline;
  final RitualKind kind;
}

enum RitualKind { release, keep }

/// 한 번의 감정 해소 세션 상태. 글 → 의식 선택 → 실행으로 흐른다.
/// 앱 전역에 [SessionScope]로 제공.
class SessionState extends ChangeNotifier {
  String _text = '';
  Ritual? _ritual;

  String get text => _text;
  Ritual? get ritual => _ritual;

  void writeText(String value) {
    _text = value;
    notifyListeners();
  }

  /// 작성 중인 글을 세션에 임시 보존한다.
  /// 화면을 다시 그릴 필요가 없으므로 알림(notify)은 하지 않는다.
  /// 의식 완료 시 [reset]이 함께 비우므로 영구 저장(기록)이 아니다.
  void saveDraft(String value) {
    _text = value;
  }

  void chooseRitual(Ritual r) {
    _ritual = r;
    notifyListeners();
  }

  /// END-04: 완료 후 홈으로 돌아가기 위한 초기화.
  void reset() {
    _text = '';
    _ritual = null;
    notifyListeners();
  }
}

class SessionScope extends InheritedNotifier<SessionState> {
  const SessionScope({
    super.key,
    required SessionState super.notifier,
    required super.child,
  });

  static SessionState of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'SessionScope가 위젯 트리에 없습니다');
    return scope!.notifier!;
  }
}
