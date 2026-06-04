import 'package:flutter/material.dart';

import 'app.dart';
import 'core/ritual_audio.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  // 저장소를 여는 동안(비동기) 잠깐 기다렸다가 앱을 시작한다.
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await StorageService.create();
  runApp(EmotionResolutionApp(storage: storage));
  // 하늘 앰비언트(just_audio) 첫 초기화 비용을 앱 시작 시 미리 치러,
  // 의식 도중(특히 태우기 완료·하늘 씬) 프레임이 멈칫하는 것을 방지(best-effort).
  RitualAudio.instance.warmUp();
}
