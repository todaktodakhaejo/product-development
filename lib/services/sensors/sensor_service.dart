import 'dart:async';
import 'dart:math';

/// 모션 센서 한 샘플 (가속도 등).
class MotionSample {
  const MotionSample(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  /// 벡터 크기 — 흔들기 강도 정규화에 사용 (PRODUCT_SPEC 5.3).
  double get magnitude => sqrt(x * x + y * y + z * z);

  static const MotionSample zero = MotionSample(0, 0, 0);
}

/// 가속도/자이로 기반 모션 입력(흔들기·기울기·던지기) 추상화.
///
/// motion-crafter(시각 물리)와 sensory-haptics(진동 강도)가 함께 소비한다.
/// 화면마다 따로 구독하지 말고 이 단일 서비스를 공유한다.
abstract class SensorService {
  /// 기울기(굴리기)용. 중력 포함.
  Stream<MotionSample> get accelerometer;

  /// 흔들기 강도용. 중력 제외(사용자 가속).
  Stream<MotionSample> get userAccelerometer;

  void dispose();
}

/// 센서 미지원(웹/에뮬레이터/구형) 폴백 — 빈 스트림.
///
/// TODO(builder/haptics): sensors_plus 패키지로 실제 스트림을 연결한
/// SensorsPlusService를 추가하고, 미지원 시 이 Noop으로 폴백한다.
class NoopSensorService implements SensorService {
  @override
  Stream<MotionSample> get accelerometer => const Stream.empty();

  @override
  Stream<MotionSample> get userAccelerometer => const Stream.empty();

  @override
  void dispose() {}
}
