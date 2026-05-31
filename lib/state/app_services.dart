import 'package:flutter/material.dart';

import '../services/audio/sound_service.dart';
import '../services/haptics/haptics.dart';
import '../services/haptics/haptics_factory.dart';
import '../services/sensors/sensor_service.dart';
import '../services/settings/settings_service.dart';

/// 앱 전역 서비스 묶음 (햅틱·사운드·센서·설정).
///
/// 한 곳에서 생성해 [AppServicesScope]로 트리에 노출한다.
class AppServices {
  AppServices({
    required this.haptics,
    required this.sound,
    required this.sensors,
    required this.settings,
  });

  final Haptics haptics;
  final SoundService sound;
  final SensorService sensors;
  final SettingsService settings;

  /// 기본 구성 — 현재는 폴백 구현. 기기 역량/패키지 연결 시 교체한다.
  factory AppServices.create() {
    return AppServices(
      haptics: HapticsFactory.create(),
      sound: NoopSoundService(),
      sensors: NoopSensorService(),
      settings: SettingsService(),
    );
  }

  void dispose() {
    sensors.dispose();
    settings.dispose();
  }
}

/// [AppServices]를 위젯 트리 어디서든 꺼내 쓰기 위한 InheritedWidget.
class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppServicesScope>();
    assert(scope != null, 'AppServicesScope를 찾을 수 없습니다.');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppServicesScope oldWidget) => false;
}
