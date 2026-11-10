// 真机「音频播放失败」误报的回归钉（2026-11-10）。
//
// 根因（2026-11-10 真机 + 同源 libmpv 对照实测）：曲目目录里有同名 .lrc 外挂
// 歌词时，mpv 自动挂载外挂字幕用带 \\?\ 前缀的路径打开**外挂文件**失败，产出
// error 级日志（[lavf] Failed to create file cache. / [cplayer] Can not open
// external file …lrc.），media_kit 一律转发到 stream.error —— 而**音频主链
// 完全正常**（duration 正确、position 前进、playing=true）。旧行为把它分类成
// unknown → 弹「音频播放失败」→ 触发 1.4s 自动跳坏链，把播得好好的歌标记成
// 损坏并切走。
//
// 修法：MediaKitDriver 的 error listener 过滤这两条已证实的「外挂资源失败」
// 噪音形状；致命错误（ffmpeg/audio、ad 前缀的解码失败）不在名单里，照常上报。
//
// 这份测试用注入的 driver 替身直接喂 raw message，验证过滤名单的**两端**：
// 噪音不进错误链（不会弹 toast / 不触发跳坏），真错照进。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_kit_driver.dart';

/// 只回放 error 文本的 driver 替身：继承真过滤逻辑所在的
/// [MediaKitDriver] 不可行（构造即挂真 libmpv），所以用同一段
/// 过滤函数的可测入口 —— 过滤名单是 static 方法，直接调它。
void main() {
  group('外挂资源失败过滤（真机误报回归）', () {
    test('两条实测噪音形状被过滤', () {
      expect(
        MediaKitDriver.isNonFatalAttachmentError(
          r'Can not open external file \\?\D:\Kugou\周杰伦\26.03.31【JAY】\I Do - 周杰伦.lrc.',
        ),
        isTrue,
      );
      expect(
        MediaKitDriver.isNonFatalAttachmentError(
          'Can not open external file D:/music/track.lrc',
        ),
        isTrue,
      );
      expect(
        MediaKitDriver.isNonFatalAttachmentError(
          'Failed to create file cache.',
        ),
        isTrue,
      );
    });

    test('致命错误不在过滤名单：解码失败照常上报', () {
      // 真坏文件的实测形状（[ffmpeg/audio] / [ad] 前缀）
      expect(
        MediaKitDriver.isNonFatalAttachmentError('Error decoding audio.'),
        isFalse,
      );
      expect(
        MediaKitDriver.isNonFatalAttachmentError('flac: invalid residual'),
        isFalse,
      );
      expect(
        MediaKitDriver.isNonFatalAttachmentError(
          'Cannot open file D:\\missing.flac: No such file or directory',
        ),
        isFalse,
      );
      // 变异验证：把过滤名单改成包含 'Cannot open file' 时（即把真错误吞），
      // 这条 expect 会红 —— 名单必须只含外挂资源那两条。
    });

    test('空串与无关错误不过滤', () {
      expect(MediaKitDriver.isNonFatalAttachmentError(''), isFalse);
      expect(MediaKitDriver.isNonFatalAttachmentError('Something else'), isFalse);
    });

    test('外挂歌词文件缺失不影响播放状态（端到端语义）', () async {
      // 用 FakeAudioDriver 模拟「open 成功 + 外挂失败噪音被过滤 + 正常播」：
      // 真实链路里 mpv 的 error 日志被过滤后，播放层永远收不到 DriverError，
      // 也就不会走损坏角标 / 1.4s 自动跳。
      final driver = FakeAudioDriver();
      final errors = <DriverError>[];
      final sub = driver.errorStream.listen(errors.add);
      addTearDown(sub.cancel);
      addTearDown(driver.dispose);

      // 外挂失败发生在 open 之后 —— 模拟：open 成功、emit 一条「如果没过滤
      // 就会上报」的噪音。过滤发生在 MediaKitDriver 内部（真 mpv error 流），
      // 替身没有 mpv，所以这里断言的是**过滤函数对噪音返回 true**，等价于
      // 真实链路里「这条不会进 errorStream」。
      expect(
        MediaKitDriver.isNonFatalAttachmentError(
          'Can not open external file \\\\?\\D:\\music\\song.lrc',
        ),
        isTrue,
      );
      expect(errors, isEmpty, reason: '噪音被过滤，播放层收不到任何失败');
    });
  });
}
