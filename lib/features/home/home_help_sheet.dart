import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'sky_background.dart';

/// 제스처 4종 사용 설명 시트(명세 §5).
///
/// 상단 우측 `?` 버튼에서 열린다. 파스텔·dreamy 톤, 이모지 지양(텍스트 +
/// CustomPaint 점 아이콘). 닫기 쉬움(바깥 탭/스와이프/닫기 버튼). 현재
/// 시간대 [SkyTone]에 맞춰 글씨·배경 대비를 잡는다.
class HomeHelpSheet extends StatelessWidget {
  const HomeHelpSheet({super.key, required this.tone});

  /// 현재 하늘 톤. 글씨/배경 대비 결정에 사용.
  final SkyTone tone;

  /// 바텀시트로 띄운다(둥근 파스텔 카드).
  static Future<void> show(BuildContext context, SkyTone tone) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      builder: (_) => HomeHelpSheet(tone: tone),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 밝은 톤이면 흰 카드+어두운 글씨, 어두운 톤이면 짙은 카드+밝은 글씨.
    final bool dark = tone == SkyTone.dark;
    final Color card = dark
        ? const Color(0xFF2A2740).withValues(alpha: 0.92)
        : Colors.white.withValues(alpha: 0.92);
    final Color title = dark ? Colors.white : const Color(0xFF4A3B47);
    final Color body =
        dark ? Colors.white70 : const Color(0xFF6B5560);
    final Color dot = dark ? AppColors.jellyCore : AppColors.jellyDeep; // 핑크 점

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 손잡이(드래그 닫기 힌트)
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: body.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '이렇게 함께 놀 수 있어요',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: title,
                ),
              ),
              const SizedBox(height: 16),
              _HelpRow(dot: dot, title: title, body: body,
                  label: '누르기', desc: '꾹 눌러 보세요, 말랑하게 들어가요.'),
              _HelpRow(dot: dot, title: title, body: body,
                  label: '흔들기', desc: '원하는 방향으로, 원하는 만큼 흔들어 봐요.'),
              _HelpRow(dot: dot, title: title, body: body,
                  label: '굴리기', desc: '손가락으로 데굴데굴 굴려 봐요.'),
              _HelpRow(dot: dot, title: title, body: body,
                  label: '쓰다듬기', desc: '살살 쓰다듬으면 은은히 빛나요.'),
              const SizedBox(height: 16),
              // 하단 안내: 진동에 맞춘 잔잔한 효과음(효과음 자체 구현은 다음 단계).
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 11, horizontal: 13),
                decoration: BoxDecoration(
                  color: dot.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '진동에 맞춰 잔잔한 효과음도 함께해요\n(벨소리·볼륨 ON)',
                  style: TextStyle(fontSize: 13, height: 1.5, color: body),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(foregroundColor: body),
                  child: const Text('닫기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 제스처 한 줄: 핑크 점 + 동작명 + 설명.
class _HelpRow extends StatelessWidget {
  const _HelpRow({
    required this.dot,
    required this.title,
    required this.body,
    required this.label,
    required this.desc,
  });

  final Color dot;
  final Color title;
  final Color body;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6, right: 12),
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '$label  ',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: title,
                    ),
                  ),
                  TextSpan(
                    text: desc,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
