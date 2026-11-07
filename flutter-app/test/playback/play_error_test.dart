// test/playback/play_error_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/play_error.dart';

void main() {
  test('白名单逐字对齐原版 11 项', () {
    expect(kAudioExtensions.length, 11);
    for (final ext in ['mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'flac', 'webm', 'weba', 'mp4']) {
      expect(isSupportedExtension(ext), isTrue, reason: ext);
    }
    expect(isSupportedExtension('MP3'), isTrue);
    expect(isSupportedExtension('txt'), isFalse);
    expect(isSupportedExtension('lrc'), isFalse);
    expect(isSupportedExtension(''), isFalse);
  });

  test('白名单容忍前导点与首尾空白', () {
    expect(isSupportedExtension('.mp3'), isTrue);
    expect(isSupportedExtension('.FLAC'), isTrue);
    expect(isSupportedExtension('  flac '), isTrue);
    expect(isSupportedExtension('.'), isFalse);
    expect(isSupportedExtension('.lrc'), isFalse);
  });

  test('文案逐字对齐原版四类', () {
    expect(kPlayErrorMessages[PlayErrorKind.aborted], '音频加载被中断，请重试');
    expect(kPlayErrorMessages[PlayErrorKind.network], '网络错误，无法获取音频文件');
    expect(kPlayErrorMessages[PlayErrorKind.decode], '音频解码失败，文件可能已损坏');
    expect(kPlayErrorMessages[PlayErrorKind.unsupported], '格式不支持或音频文件不存在');
    expect(kPlayErrorMessages[PlayErrorKind.unknown], '音频播放失败，请稍后重试');
  });

  test('分类优先级：不支持 > 解码 > 中断', () {
    expect(classifyFailure(fileName: 'a.txt'), PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', notFound: true), PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'Invalid data found when processing input'),
        PlayErrorKind.decode);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'Failed to recognize file format'),
        PlayErrorKind.decode);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'no such file or directory'),
        PlayErrorKind.unsupported);
    // mpv 的 `Failed to open <path>`：文件被移走 / 删掉，不能谎称「文件可能已损坏」。
    expect(classifyFailure(rawMessage: 'Failed to open file'), PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'stream interrupted'),
        PlayErrorKind.aborted);
    expect(classifyFailure(fileName: 'a.flac'), PlayErrorKind.unknown);
  });

  test('网络错误落在中断之后', () {
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'Connection reset by peer'),
        PlayErrorKind.network);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'Network unreachable'),
        PlayErrorKind.network);
  });

  test('空输入不抛异常且兜底 unknown', () {
    expect(classifyFailure(), PlayErrorKind.unknown);
    expect(classifyFailure(fileName: '', rawMessage: '   '), PlayErrorKind.unknown);
    expect(classifyFailure(rawMessage: 'something weird'), PlayErrorKind.unknown);
  });

  test('extensionOf 取最后一段并小写、无扩展名为空串', () {
    expect(extensionOf('/music/a.FLAC'), 'flac');
    expect(extensionOf('a.b.mp3'), 'mp3');
    expect(extensionOf('/music/noext'), '');
    expect(extensionOf(''), '');
  });

  test('errorMessageFor 覆盖全部五种', () {
    for (final kind in PlayErrorKind.values) {
      expect(errorMessageFor(kind), kPlayErrorMessages[kind]);
      expect(errorMessageFor(kind), isNotEmpty);
    }
    expect(kPlayErrorMessages.length, PlayErrorKind.values.length);
  });

  test('自动播放受阻文案', () {
    expect(kAutoplayBlockedMessage, '无法开始播放，请点击播放按钮开始');
  });
}
