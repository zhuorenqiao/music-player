// lib/lyrics/netease_match.dart
//
// 对译 React 版 src/server/music-api.ts:417-561：normText、coreTitle、artistNames、
// artistHitSong、pickTranslatableSong、translatePairs，以及搜索结果 `result.songs`
// 的安全解析（music-api.ts:524-529）。纯函数、无 IO、无状态、无 Flutter 依赖。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/lyrics/netease_match_test.dart）：
// * normText 的字符类是**第三套**，与 T9 的 translate_lang / translate_align 都不同：
//   含全角 `！？` 和 `«»『』「」`，但**不含**括号（括号留给 coreTitle 的前缀逻辑）。
//   别改去复用 T9 那两套，否则全角问号的歌名会归一不一致；
// * coreTitle 的括号剥离是 while 到不动点（`(Live)(Remastered)` 要逐层剥，见
//   `(feat. a) [Live] 【伴奏】` 那条），且括号内容类排除括号本身 → **不跨嵌套**
//   （`十年 (甲 (乙))` 剥不动）；剥完括号再单剥一个尾部分隔符，分隔符只认半角 `-–—:,;`，
//   而且**只剥一个**（`十年 - ,` 留 `十年 - `）；
// * trimEnd / trim 用的是 JS 的空白集合（== `\s`），不是 Dart 的 `trim()`：
//   Dart 还认 U+0085（NEL），JS 不认，所以不能直接用内建 trim；
// * artistHitSong 先按 `/ 、 , & feat.` 拆成一个个歌手名再比：只做「整串包含」会误配
//   （`Zzzx Nope` 归一后能包含 `nope`，点号被 normText 吃掉了）；token 长度 ≥3 才开
//   前缀比较，且前缀是**双向**的（token 以 wantArtist 开头 或 wantArtist 以 token 开头）。
//   `feat.` 的 `\b` 会切出一个带点的碎片（`A feat. B` → `A ` / `. B`），靠 normText 吃掉点；
//   入参 wantArtist 由调用方先归一化，本函数**不再**归一化（JS 就是直接比）；
// * pickTranslatableSong 里 song.duration 是**毫秒**，要 /1000 再与秒级 duration 比；
//   无法折算时 diff = +Infinity（Dart 用 double.infinity），于是前缀路径只能靠歌手；
//   前缀路径另有硬上限 diff > 20 直接淘汰（diff === 20 保留）；
// * titleExact 第三条分支与 titlePrefix 各有一个 `>= 3` 门槛，方向别混：前者比的是
//   归一后的**曲名本体** wantCore，后者比的是**整串** wantTitle；
// * score > bestScore 是**严格大于**：同分保留搜索结果里靠前的，bestScore 初值 0 → 0 分不选；
// * translatePairs 的去重发生在「对调 + 拆分」都 push 完之后；调用方在**去重之后**才追加
//   `{name: trackName, artist: '', strict: false}`，那条不参与去重（见 translate_source.dart）。
//
// 与 JS 的一处有意加固：parseNetEaseSong 只收 String 类型的 artists[].name / alias[]，
// JSON 的 num 只收有限数，不做 `String(...)` 强转——搜索结果里混一条怪数据不该让整次匹配
// 失败，也不该被强转成一个能误配的歌手名。

/// 归一化要剥的空白：`\s` 之外**额外**含全角空格 U+3000，music-api.ts:420。
final RegExp _spaces = RegExp(r'[\s　]');

/// 归一化要剥的标点，music-api.ts:421。全角 `！？` 与 `«»『』「」` 都在。
///
/// 逐字照抄，不要与 T9 的 translate_align（只有半角 `!`）合并。
final RegExp _punct = RegExp(r'''[,.;:!?·、。，．：；！？"'«»『』「」]''');

/// 尾部括号说明，music-api.ts:433。括号内含 `[^()（）【】\[\]]` → 遇嵌套即不匹配。
final RegExp _tailParen = RegExp(r'\s*[(（【[][^()（）【】\[\]]*[)）】\]]\s*$');

/// 尾部分隔符，music-api.ts:435。只认半角，全角 `：，` 不在类里。
final RegExp _tailSeparator = RegExp(r'\s*[-–—:,;]\s*$');

/// 歌手名拆分符，music-api.ts:450。`feat.` 的 `\b` 会留下一个点，由 [_punct] 吃掉。
final RegExp _artistSep = RegExp(
  r'/|[、,，&；;]|\bfeat\.?\b',
  caseSensitive: false,
);

/// 曲名 / 歌手拆分用的「头 - 尾」，music-api.ts:546。
///
/// 三个要点：破折号两侧都要有 `\s+`；两侧各 2~60 字符（`{2,60}?` 惰性 → 按第一个
/// 破折号拆）；`.` 不匹配换行、`$` 只认整串末尾（JS 无 `s` / `m` 标志）。
final RegExp _titleSplit = RegExp(r'^(.{2,60}?)\s+[-–—]\s+(.{2,60})$');

/// 一条网易云搜索结果（music-api.ts:398-404）。
class NetEaseSong {
  const NetEaseSong({
    required this.id,
    required this.name,
    this.durationMs = 0,
    this.artists = const [],
    this.alias = const [],
  });

  final int id;

  final String name;

  /// 毫秒。与 [pickTranslatableSong] 的 `duration`（秒）不是同一单位。
  final double durationMs;

  /// 歌手名，已由 [parseNetEaseSong] 拍平成字符串。
  final List<String> artists;

  /// 别名（同名不同语的曲名）。
  final List<String> alias;
}

/// 一次认歌尝试的「曲名 + 歌手」，music-api.ts:541-561。
class TranslateCandidate {
  const TranslateCandidate({
    required this.name,
    required this.artist,
    required this.strict,
  });

  final String name;

  final String artist;

  /// 派生候选（对调、从曲名里拆出来的）必须另有歌手证据才认，music-api.ts:462-463。
  final bool strict;

  /// 搜索词：`[artist, name]` 用单空格连接，**歌手在前**（music-api.ts:572）。
  String get keyword =>
      [artist, name].where((part) => part.isNotEmpty).join(' ');
}

/// 匹配用的归一化：小写、去空白与常见标点，括号说明留着（靠前缀判断）。
///
/// music-api.ts:417-421。标点类见 [_punct] 的注释。
String normText(String value) =>
    value.toLowerCase().replaceAll(_spaces, '').replaceAll(_punct, '');

/// 去掉尾部的括号说明与分隔符，得到「歌名本体」，music-api.ts:428-436。
///
/// 《Old Town Road (feat. X)》→《Old Town Road》。循环到不动点，
/// 所以 `(Live)[Remastered]` 这种连写的后缀能逐层剥干净。
///
/// 用 `\s` 而不是 Dart 的 `trim()`：JS 的 trim 不认 U+0085（NEL），Dart 认。
String coreTitle(String value) {
  var text = value;
  var before = '';
  while (before != text) {
    before = text;
    text = text.replaceFirst(_tailParen, '').replaceFirst(_tailSpace, '');
  }
  return text
      .replaceFirst(_tailSeparator, '')
      .replaceFirst(_headSpace, '')
      .replaceFirst(_tailSpace, '');
}

/// JS 语义的「尾部空白」（== `\s`，不含 Dart 独有的 U+0085）。
final RegExp _tailSpace = RegExp(r'\s+$');

/// JS 语义的「首部空白」。
final RegExp _headSpace = RegExp(r'^\s+');

/// JS 语义的 `String.prototype.trim`：两端各剥一遍 `\s`（不含 U+0085）。
String _jsTrim(String value) =>
    value.replaceFirst(_headSpace, '').replaceFirst(_tailSpace, '');

/// 歌手名，只留非空的（music-api.ts:423-425 的 `artistNames`）。
List<String> _artistNames(NetEaseSong song) => [
  for (final name in song.artists)
    if (name.isNotEmpty) name,
];

/// 歌手证据，music-api.ts:445-455。
///
/// [wantArtist] 由调用方先 `normText`（本函数不再归一化，与 JS 一致）。
bool artistHitSong(NetEaseSong song, String wantArtist) {
  if (wantArtist.isEmpty) return false;
  final tokens = <String>[];
  for (final value in _artistNames(song)) {
    for (final part in value.split(_artistSep)) {
      final token = normText(part);
      if (token.isNotEmpty) tokens.add(token);
    }
  }
  return tokens.any(
    (token) =>
        token == wantArtist ||
        (token.length >= 3 &&
            (token.startsWith(wantArtist) || wantArtist.startsWith(token))),
  );
}

/// 从搜索结果里挑唯一可信的一条，music-api.ts:465-522。
///
/// 译文库错配比歌词错配更糟——整页中文都是别的歌的，用户很难当场发现。
/// 所以门槛收紧：歌名必须一致（含去掉版本后缀的本体），且歌手对得上或时长差在 6 秒内。
///
/// [duration] 是**秒**，0 表示未知；[strict] 为真时必须有歌手证据：
/// 派生候选里「歌手」本身是猜的，只靠时长很容易配上同名不相干的歌。
NetEaseSong? pickTranslatableSong(
  List<NetEaseSong> songs, {
  required String trackName,
  required String artistName,
  required int duration,
  bool strict = false,
}) {
  final wantTitle = normText(trackName);
  final wantCore = normText(coreTitle(trackName));
  final wantArtist = normText(artistName);
  if (wantTitle.isEmpty) return null;
  // 既没有歌手也没有时长可比：只剩歌名这一个证据，歌名全等就认。
  final onlyTitle = wantArtist.isEmpty && !(duration > 0);

  NetEaseSong? best;
  var bestScore = 0;
  for (final song in songs) {
    final name = normText(song.name);
    if (name.isEmpty || song.id == 0) continue;
    final core = normText(coreTitle(song.name));
    final titleExact =
        name == wantTitle ||
        song.alias.any((alias) => normText(alias) == wantTitle) ||
        (wantCore.length >= 3 && core == wantCore);
    // 「Yellow (Acoustic)」「Yellow (Live)」这类带后缀的版本；单向，且 wantTitle 要够长。
    final titlePrefix =
        !titleExact && wantTitle.length >= 3 && name.startsWith(wantTitle);
    if (!titleExact && !titlePrefix) continue;
    final artistHit = artistHitSong(song, wantArtist);
    // song.duration 是毫秒；无法折算时按「不知道」处理（JS 的 +Infinity）。
    final millis = song.durationMs;
    final diff = duration > 0 && millis.isFinite && millis > 0
        ? (millis / 1000 - duration).abs()
        : double.infinity;
    final durHit = diff <= 6;
    if (!titleExact) {
      // 前缀命中必须靠时长或歌手背书，否则「Yellow」会配上「Yellow (Live)」那种
      // 6 分钟版本；背书之后还有 20 秒的硬上限。
      if (!artistHit && !durHit) continue;
      if (diff > 20) continue;
    } else if (!artistHit && !durHit && !onlyTitle) {
      continue;
    }
    if (strict && !artistHit) continue;
    final score =
        (titleExact ? 40 : 18) + (artistHit ? 25 : 0) + (durHit ? 25 : 0);
    // 严格大于：同分保留搜索结果里靠前的；初值 0 → 0 分不选。
    if (score > bestScore) {
      best = song;
      bestScore = score;
    }
  }
  return best;
}

/// 三种（曲名, 歌手）拆法，music-api.ts:541-561。
///
/// 本地导入的标签有三种写法：正拆、反拆、以及曲名本身写着「歌名 - 歌手」。
/// 歌词代理那边有对调重试，这边三种都试一遍才追得平——否则表现是
/// 「歌词有、双语开关也在，但永远查不到译文」。
///
/// 末尾那条 `{name: trackName, artist: '', strict: false}` **不在这里**：
/// 调用方是在去重之后才追加的（artist 为空时会重复搜一次，照抄原版）。
List<TranslateCandidate> translatePairs(String trackName, String artistName) {
  final pairs = <TranslateCandidate>[
    TranslateCandidate(name: trackName, artist: artistName, strict: false),
  ];
  if (artistName.isNotEmpty && artistName != trackName) {
    pairs.add(
      TranslateCandidate(name: artistName, artist: trackName, strict: true),
    );
  }
  final split = _titleSplit.firstMatch(trackName);
  if (split != null) {
    // JS 的 `head.trim()` / `tail.trim()` 用的是 JS 空白集合（== `\s`），
    // **不含** Dart 独有的 U+0085（NEL）——见文件头与 coreTitle 的同一条裁定。
    // 内建 `.trim()` 在 NEL 边界上与 JS 不同（实测 'ab\u0085' 会被 Dart 剥成
    // 'ab' 而 JS 保留），所以这里用与 `\s` 同集合的正则 trim。
    final head = _jsTrim(split.group(1)!);
    final tail = _jsTrim(split.group(2)!);
    pairs.add(TranslateCandidate(name: head, artist: tail, strict: true));
    pairs.add(TranslateCandidate(name: tail, artist: head, strict: true));
  }
  final seen = <String>{};
  return [
    for (final pair in pairs)
      if (seen.add('${pair.name}|${pair.artist}'.toLowerCase())) pair,
  ];
}

/// 从 JSON 里安全取一条 [NetEaseSong]，脏数据返回 null（music-api.ts:524-529）。
///
/// `id` 必须是 num、有限、> 0、整数值（JSON 里的 `5.0` 也接受，取 `5`），否则整条丢掉；
/// `name` 非 String → `''`；`duration` 非有限 num → `0`；`artists` 逐条取非空 `name`；
/// `alias` 只收 String。**绝不抛**：搜索结果里混一条怪数据不该让整次匹配失败。
NetEaseSong? parseNetEaseSong(Object? raw) {
  if (raw is! Map) return null;
  final id = _readId(raw['id']);
  if (id == null) return null;
  final duration = raw['duration'];
  return NetEaseSong(
    id: id,
    name: _readString(raw['name']) ?? '',
    durationMs: duration is num && duration.isFinite ? duration.toDouble() : 0,
    artists: _readArtistNames(raw['artists']),
    alias: _readStrings(raw['alias']),
  );
}

/// `id` 必须是正整数值的 num；`5.0` 收，`5.5` / `'5'` / `0` 不收。
int? _readId(Object? raw) {
  if (raw is! num || !raw.isFinite || raw <= 0) return null;
  if (raw != raw.truncateToDouble()) return null;
  return raw.toInt();
}

String? _readString(Object? raw) => raw is String ? raw : null;

/// `artists` 逐条取 `{name: String}` 的非空 name，其余（字符串、null、缺 name）丢掉。
List<String> _readArtistNames(Object? raw) {
  if (raw is! List) return const [];
  final names = <String>[];
  for (final artist in raw) {
    if (artist is! Map) continue;
    final name = _readString(artist['name']);
    if (name != null && name.isNotEmpty) names.add(name);
  }
  return names;
}

/// `alias` 只收 String。
List<String> _readStrings(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final value in raw)
      if (value is String) value,
  ];
}

/// 读 `result.songs`，非数组 / 非 Map 给空表（music-api.ts:527-528）。
///
/// 逐条过 [parseNetEaseSong] 并丢掉 null，所以脏条目只损失它自己。
List<NetEaseSong> parseNetEaseSongs(Object? raw) {
  if (raw is! Map) return const [];
  final result = raw['result'];
  if (result is! Map) return const [];
  final songs = result['songs'];
  if (songs is! List) return const [];
  final parsed = <NetEaseSong>[];
  for (final song in songs) {
    final one = parseNetEaseSong(song);
    if (one != null) parsed.add(one);
  }
  return parsed;
}
