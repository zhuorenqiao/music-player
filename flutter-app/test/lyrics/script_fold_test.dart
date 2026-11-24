// test/lyrics/script_fold_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/script_fold.dart';

void main() {
  test('繁体曲名/歌手折到简体，key 跟着重算', () {
    final raw = normalizeQuery(
      title: '完美主義',
      artist: '周杰倫',
      duration: 244.6,
    );
    final folded = foldQuery(raw);
    expect(folded.trackName, '完美主义');
    expect(folded.artistName, '周杰伦');
    expect(folded.duration, raw.duration);
    expect(folded.key, '完美主义|周杰伦|${raw.duration}');
    expect(foldChangedByScript(raw, folded), isTrue);
  });

  test('已是简体（或非中文）时原样返回同一个对象', () {
    final raw = normalizeQuery(
      title: '完美主义',
      artist: '周杰伦',
      duration: 244,
    );
    expect(identical(foldQuery(raw), raw), isTrue);
    expect(foldChangedByScript(raw, foldQuery(raw)), isFalse);
  });

  test('只有歌手是繁体也折', () {
    final raw = normalizeQuery(title: '完美主义', artist: '周杰倫', duration: 244);
    final folded = foldQuery(raw);
    expect(folded.trackName, '完美主义');
    expect(folded.artistName, '周杰伦');
    expect(folded.key, '完美主义|周杰伦|244');
  });
}
