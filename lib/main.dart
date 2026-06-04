import 'package:flutter/material.dart';

import 'app.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  // 저장소를 여는 동안(비동기) 잠깐 기다렸다가 앱을 시작한다.
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await StorageService.create();
  runApp(EmotionResolutionApp(storage: storage));
}
