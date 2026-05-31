import 'dart:math';

/// HOME-03 위로 멘트 후보. 진입 시 하나 노출 → 오브제 만지면 사라짐.
const List<String> kComfortMessages = [
  '마음보다 손이 먼저 가도 괜찮아요',
  '여기 있어요',
  '뭐든 괜찮아요',
  '잠시 이곳에 내려두세요',
];

/// END-03 완료 멘트.
const String kCompletionMessage = '다 보냈어요';

String randomComfortMessage([Random? rng]) {
  final r = rng ?? Random();
  return kComfortMessages[r.nextInt(kComfortMessages.length)];
}
