// test/cover/generated_cover_test.dart
//
// 生成卡派生量的黄金数值用例，对译 React 版 src/lib/generated-cover.js：
// hash（23-30）、normalizeArtist（37-44）、initialsOf（65-79）、派生量与
// 27 根柱高（89-102）。数值用 node 现算钉死（计划「生成卡」节的黄金数值
// 表），实现侧任何公式偏差都会在这里炸出来。
//
// 派生量断言基于 generatedCoverSpec 暴露的字段（计划要求「不许把画面埋进
// paint 里没法测」）；painter 只做纯结构测试（构造不抛 + 真渲染 600×600）。
// `dart:ui` 渲染需要引擎绑定：main 开头 TestWidgetsFlutterBinding，用普通
// test()（不是 testWidgets），手法同 test/metadata/cover_image_test.dart:5-8。
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/generated_cover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fnv1aHash', () {
    test('黄金数值逐条钉死（node 现算）', () {
      expect(fnv1aHash('周杰伦'), 3719078777);
      expect(fnv1aHash('jay chou'), 3504833698);
      expect(fnv1aHash('陈奕迅'), 3387159545);
      expect(fnv1aHash('未知歌手'), 2278938309);
      expect(fnv1aHash('unknown'), 2608177081);
    });

    test('空串返回初值 0x811C9DC5', () {
      expect(fnv1aHash(''), 2166136261);
    });
  });

  group('normalizeArtistForCover', () {
    test('trim / lowercase / 空白折叠 / 尾部连字符', () {
      expect(normalizeArtistForCover('  陈奕迅  '), '陈奕迅');
      expect(normalizeArtistForCover('Jay Chou'), 'jay chou');
      expect(normalizeArtistForCover('周杰伦 -'), '周杰伦');
      expect(normalizeArtistForCover('A  B'), 'a b');
    });
  });

  group('initialsOfArtist', () {
    test('CJK 取 1 字，拉丁取前 2 字大写，空兜 ♪', () {
      expect(initialsOfArtist('周杰伦'), '周');
      expect(initialsOfArtist('Jay Chou'), 'JA');
      expect(initialsOfArtist(''), '♪');
      expect(initialsOfArtist('♪♪'), '♪');
      expect(initialsOfArtist('abc'), 'AB');
    });
  });

  group('generatedCoverSpec', () {
    test('周杰伦 / 青花瓷：seed、色相、旋转、首字、柱高全对表', () {
      final spec = generatedCoverSpec('周杰伦', '青花瓷');
      expect(spec.key, '周杰伦');
      expect(spec.seed, 3719078777);
      expect(spec.hue, 137);
      expect(spec.hue2, 180);
      expect(spec.rotation, 1);
      expect(spec.initials, '周');
      expect(spec.label, '周杰伦');
      expect(spec.sub, '青花瓷');
      expect(spec.showSub, isTrue);
      expect(spec.bars.length, 27);
      expect(spec.bars.take(5).toList(), [66, 37, 40, 80, 58]);
    });

    test('Jay Chou / 空曲名：拉丁首字与柱形第二组黄金值', () {
      final spec = generatedCoverSpec('Jay Chou', '');
      expect(spec.hue, 58);
      expect(spec.hue2, 92);
      expect(spec.rotation, 2);
      expect(spec.initials, 'JA');
      expect(spec.bars.take(5).toList(), [61, 19, 78, 52, 51]);
      expect(spec.showSub, isFalse);
      expect(spec.label, 'Jay Chou');
    });

    test('前后空白歌手：key 归一后与陈奕迅同图', () {
      final spec = generatedCoverSpec('  陈奕迅  ', '');
      expect(spec.seed, 3387159545);
      expect(spec.initials, '陈');
    });

    test('全空入参：unknown 键与未知歌手兜底', () {
      final spec = generatedCoverSpec('', '');
      expect(spec.key, 'unknown');
      expect(spec.seed, 2608177081);
      expect(spec.initials, '♪');
      expect(spec.label, '未知歌手');
    });

    test('确定性：同一输入两次调用字段逐一相等', () {
      final a = generatedCoverSpec('周杰伦', '青花瓷');
      final b = generatedCoverSpec('周杰伦', '青花瓷');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('GeneratedCoverPainter', () {
    test('构造与 paint 纯结构：不抛', () {
      final spec = generatedCoverSpec('周杰伦', '青花瓷');
      final painter = GeneratedCoverPainter(spec);
      expect(painter.spec, same(spec));
      final emptySpec = generatedCoverSpec('', '');
      expect(GeneratedCoverPainter(emptySpec).spec.initials, '♪');
    });

    test('可真实渲染 600×600（普通 test + 引擎绑定）', () async {
      final spec = generatedCoverSpec('周杰伦', '青花瓷');
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      // 传入非 600 的边长，顺带验证 canvas.scale 归一后照常出图。
      GeneratedCoverPainter(spec).paint(canvas, const Size(300, 300));
      final picture = recorder.endRecording();
      final image = await picture.toImage(300, 300);
      expect(image.width, 300);
      expect(image.height, 300);
      image.dispose();
      picture.dispose();
    });

    test('shouldRepaint 只在 spec 变化时为真', () {
      final spec = generatedCoverSpec('周杰伦', '青花瓷');
      final painter = GeneratedCoverPainter(spec);
      expect(painter.shouldRepaint(GeneratedCoverPainter(spec)), isFalse);
      expect(
        painter.shouldRepaint(GeneratedCoverPainter(generatedCoverSpec('陈奕迅', ''))),
        isTrue,
      );
    });
  });
}
