// test/lyrics/netease_match_test.dart
//
// 对表 src/server/music-api.ts:417-561 的认歌打分与候选关键词生成。
// 每条期望值都用 node 跑过真实 JS 实现（把 music-api.ts:417-561 的六个函数逐字复制成 mjs），
// 不是从注释或 brief 推的；与 brief 初稿期望不一致的六处已在行内注明原因（「parity 校正」）。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/netease_match.dart';

NetEaseSong song({
  int id = 1,
  String name = '十年',
  double durationMs = 300000,
  List<String> artists = const ['陈奕迅'],
  List<String> alias = const [],
}) => NetEaseSong(
  id: id,
  name: name,
  durationMs: durationMs,
  artists: artists,
  alias: alias,
);

void main() {
  group('normText', () {
    test('小写、去空白（含全角空格）、去常见标点，保留括号', () {
      expect(normText(' 十 年 '), '十年');
      expect(normText('Ten Years'), 'tenyears');
      // 半角与全角圆括号都不在字符类里 → 原样保留（靠 coreTitle 的前缀逻辑处理）
      expect(normText('（十年）'), '（十年）');
      expect(normText('(十年)'), '(十年)');
      expect(normText('N.O.P.E'), 'nope');
      expect(normText('「十年」'), '十年');
    });

    test('字符类含全角 ！？ 与 «»『』「」——这是第三套，别抄 T9 的两套', () {
      // translate_align 的字符类只有半角 !，全角 ！ 会留着；这里两套都剥
      expect(normText('A！？B'), 'ab');
      expect(normText('A!?B'), 'ab');
      expect(normText('«十年»『甲』「乙」'), '十年甲乙');
      // 全角空格 U+3000 与 \s 一并剥掉
      expect(normText('甲　乙'), '甲乙');
      // ，．：；、。· 全在类里
      expect(normText('，．：；、。·'), '');
    });
  });

  group('coreTitle', () {
    test('循环剥尾部括号，直到不动点', () {
      expect(coreTitle('十年 (feat. 甲) (Live)'), '十年');
      expect(coreTitle('十年【伴奏】'), '十年');
      // 三种括号混排 + 多层：逐层剥到不动点
      expect(coreTitle('Yellow (feat. a) [Live] 【伴奏】'), 'Yellow');
      expect(coreTitle('Yellow (Live) (Remastered)'), 'Yellow');
      // 全角圆括号、无空格直接贴括号也算尾部括号
      expect(coreTitle('Yellow （Live）'), 'Yellow');
      expect(coreTitle('Yellow(甲)'), 'Yellow');
    });

    test('只剥尾部，中间括号保留', () {
      expect(coreTitle('十 (Live) 年'), '十 (Live) 年');
      expect(coreTitle('十年 (甲) 乙'), '十年 (甲) 乙');
    });

    test('不跨嵌套括号', () {
      // 括号内容类 [^()（）【】\[\]] 排除了括号，嵌套时匹配不到末尾的 ) → 不剥
      // brief 原期望 '十年' 与此不符（parity 校正）
      expect(coreTitle('十年 (甲 (乙))'), '十年 (甲 (乙))');
    });

    test('最后剥一个尾部 - – — : , ;（半角，不剥全角）', () {
      expect(coreTitle('十年 -'), '十年');
      expect(coreTitle('十年 –'), '十年');
      expect(coreTitle('十年 —'), '十年');
      expect(coreTitle('十年:'), '十年');
      expect(coreTitle('十年,'), '十年');
      expect(coreTitle('十年;'), '十年');
      // JS 的类是半角 [-–—:,;]，全角 ：／， 都不剥
      // brief 原期望 coreTitle('十年：') == '十年' 与此不符（parity 校正）
      expect(coreTitle('十年：'), '十年：');
      expect(coreTitle('十年，'), '十年，');
    });

    test('最后一跳在括号剥完之后：括号后面挂分隔符也能剥干净', () {
      expect(coreTitle('Yellow (Live) - '), 'Yellow (Live)');
      expect(coreTitle('  十年  '), '十年');
      // 括号后是分隔符时，先剥分隔符不再回头剥括号（单趟 while 已到不动点）
      expect(coreTitle('十年 (Live)：'), '十年 (Live)：');
    });

    test('残缺括号不抛也不剥', () {
      expect(coreTitle('十年 ('), '十年 (');
      expect(coreTitle('十年 )'), '十年 )');
    });

    test('trim 用 JS 的空白集合：NEL(U+0085) 不剥，Dart 的 trim() 会剥', () {
      // JS 的 \s / trim 都不含 U+0085；Dart 的 String.trim() 含。
      // 这条钉住「别把实现换成 trimRight()」（detail：JS coreTitle('十年\u0085') === '十年\u0085'）
      final nel = String.fromCharCode(0x85);
      expect(coreTitle('十年$nel'), '十年$nel');
      expect(coreTitle('十年$nel(Live)'), '十年$nel');
      // 全角空格、NBSP、制表符都在 JS 的 \s 里 → 照剥
      expect(coreTitle('十年\u3000(Live)'), '十年');
      expect(coreTitle('十年\u00a0(Live)'), '十年');
      expect(coreTitle('十年\t(Live)'), '十年');
    });
  });

  group('artistHitSong', () {
    test('全等命中', () {
      expect(artistHitSong(song(), '陈奕迅'), isTrue);
    });

    test('空 wantArtist 恒 false', () {
      expect(artistHitSong(song(), ''), isFalse);
    });

    test('分隔符拆开后逐个比', () {
      final s = song(artists: ['陈奕迅 / 王菲']);
      expect(artistHitSong(s, '王菲'), isTrue);
      expect(artistHitSong(s, '陈奕迅'), isTrue);
      // token 是「陈奕迅」「王菲」，wantArtist '陈奕迅王菲' 以 token 开头 →
      // 双向前缀比较里 wantArtist.startsWith(token) 成立 → true
      // brief 原期望 false 与此不符（parity 校正）
      expect(artistHitSong(s, '陈奕迅王菲'), isTrue);
      // 不做整串包含：token 是「奕迅」时既不相等也不是前缀关系
      expect(artistHitSong(s, '奕迅'), isFalse);
    });

    test('feat. 也拆（拆完会留下一个点，由 normText 吃掉）', () {
      final s = song(artists: ['A feat. B']);
      // 'A feat. B'.split → ['A ', '. B'] → normText → ['a', 'b']
      // wantArtist 由调用方先 normText（本函数不再归一化），所以传小写
      // brief 原期望传 'B'/'A' 为 true，与 JS 实测不符（parity 校正）
      expect(artistHitSong(s, 'b'), isTrue);
      expect(artistHitSong(s, 'a'), isTrue);
      // 印证「不再归一化」：大写 wantArtist 比较不上（JS 同样比较不上）
      expect(artistHitSong(s, 'B'), isFalse);
      expect(artistHitSong(song(artists: ['甲 feat. 乙']), '乙'), isTrue);
    });

    test('token ≥3 才允许前缀匹配', () {
      expect(artistHitSong(song(artists: ['陈奕迅乐队']), '陈奕迅'), isTrue);
      // 门槛看的是 **token** 的长度，不是 wantArtist 的：
      // token 'abc'（3）以 wantArtist 'abcd' 开头 → 开闸
      expect(artistHitSong(song(artists: ['abc']), 'abcd'), isTrue);
      // token 'ab'（2）→ 门槛未开，哪怕关系成立也不认
      expect(artistHitSong(song(artists: ['ab']), 'abcd'), isFalse);
      // 「AB乐队」归一后是 'ab乐队'（4 字符）→ 门槛是开的，前缀关系成立 → true。
      // brief 原用例写 artistHitSong(song(['AB乐队']), 'AB') 期望 false，是因为传了**未归一化**
      // 的大写 'AB'（JS 逐字节比较才 false），不是因为门槛；这里用归一化入参钉住真语义
      // （parity 校正）
      expect(artistHitSong(song(artists: ['AB乐队']), 'ab'), isTrue);
      // 印证「本函数不归一化入参」：大写 wantArtist 比不过小写 token（JS 同）
      expect(artistHitSong(song(artists: ['AB乐队']), 'AB'), isFalse);
    });

    test('不做整串包含：Zzzx Nope vs N.O.P.E 必须为假', () {
      // 归一化后 token 是 'zzzxnope'，wantArtist 是 'nope'；不以对方开头 → false
      expect(artistHitSong(song(artists: ['Zzzx Nope']), 'nope'), isFalse);
    });
  });

  group('pickTranslatableSong', () {
    test('名字全等 + 歌手命中 + 时长命中 → 90 分', () {
      final picked = pickTranslatableSong(
        [song()],
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('别名全等也算 titleExact', () {
      final picked = pickTranslatableSong(
        [
          song(name: 'Ten Years', alias: ['十年']),
        ],
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('wantCore ≥3 时尾括号剥离后相等也算 titleExact', () {
      // wantCore = normText(coreTitle('Yellow (Remastered)')) = 'yellow'（6 ≥ 3）
      final picked = pickTranslatableSong(
        [
          song(name: 'Yellow (Live)', artists: ['陈奕迅']),
        ],
        trackName: 'Yellow (Remastered)',
        artistName: '',
        duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('wantCore 不足 3 字符时该分支关闭', () {
      // wantCore = '十年'（2 字符）→ 第三条 titleExact 分支不成立；
      // '十年 (Remastered)' 也不以 '十年 (Live)' 开头 → 整条淘汰
      final picked = pickTranslatableSong(
        [song(name: '十年 (Remastered)')],
        trackName: '十年 (Live)',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked, isNull);
    });

    test('时长容差 ≤6s（含等号），7s 不算', () {
      final picked6 = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 306000),
        ],
        trackName: '十年',
        artistName: '',
        duration: 300,
      );
      expect(picked6, isNotNull);
      final picked7 = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 307000),
        ],
        trackName: '十年',
        artistName: '',
        duration: 300,
      );
      expect(picked7, isNull);
    });

    test('时长是毫秒：必须 /1000 再比（否则差 300 秒全淘汰）', () {
      // 300000ms = 300s，与 duration 300 秒一致 → diff 0
      final picked = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 300000),
        ],
        trackName: '十年',
        artistName: '',
        duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('前缀命中：wantTitle 不足 3 字符时前缀路径整个关闭', () {
      // '十年 (Live)' 归一到 '十年(live)'，与 wantTitle '十年' 不等；
      // 但 wantTitle 只有 2 字符 → titlePrefix 恒 false（哪怕歌手/时长都对）
      // brief 原期望 near/far 一条 notNull 一条 isNull，与 JS 实测不符（parity 校正）
      expect(
        pickTranslatableSong(
          [song(name: '十年 (Live)')],
          trackName: '十年',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
      expect(
        pickTranslatableSong(
          [
            song(name: '十年 (Live)', artists: ['陈奕迅']),
          ],
          trackName: '十年',
          artistName: '陈奕迅',
          duration: 300,
        ),
        isNull,
      );
    });

    test('前缀命中（3 字符起）：无歌手无时长时淘汰，有时长 20s 内保留', () {
      // 'Yellow Live' 以 'Yellow' 开头 → titlePrefix（wantTitle 6 ≥ 3）
      final noInfo = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['别人']),
        ],
        trackName: 'Yellow',
        artistName: '',
        duration: 0,
      );
      expect(noInfo, isNull);
      // 只有歌手命中、没有时长：diff = +Infinity → diff > 20 直接淘汰
      final artistOnly = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['Coldplay']),
        ],
        trackName: 'Yellow',
        artistName: 'Coldplay',
        duration: 0,
      );
      expect(artistOnly, isNull);
      // 时长命中（diff 0）→ 保留
      final near = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['别人']),
        ],
        trackName: 'Yellow',
        artistName: '',
        duration: 300,
      );
      expect(near, isNotNull);
    });

    test('前缀命中的 diff 上限：20s 保留，20.5s 淘汰', () {
      final at20 = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['Coldplay'], durationMs: 320000),
        ],
        trackName: 'Yellow',
        artistName: 'Coldplay',
        duration: 300,
      );
      expect(at20, isNotNull);
      final at205 = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['Coldplay'], durationMs: 320500),
        ],
        trackName: 'Yellow',
        artistName: 'Coldplay',
        duration: 300,
      );
      expect(at205, isNull);
      // 30s 差即使歌手命中也被 diff > 20 淘汰（前缀路径）
      final far = pickTranslatableSong(
        [
          song(name: 'Yellow Live', artists: ['Coldplay'], durationMs: 330000),
        ],
        trackName: 'Yellow',
        artistName: 'Coldplay',
        duration: 300,
      );
      expect(far, isNull);
    });

    test('前缀是单向的：反向（wantTitle 更长）不成立', () {
      expect(
        pickTranslatableSong(
          [
            song(name: 'Yellow', artists: ['别人']),
          ],
          trackName: 'Yellow Live',
          artistName: '',
          duration: 300,
        ),
        isNull,
      );
    });

    test('titleExact 但歌手与时长都不对，且信息不全 → 淘汰', () {
      final picked = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 0),
        ],
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked, isNull);
    });

    test('onlyTitle（无歌手无时长）时 titleExact 直接通过', () {
      final picked = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 0),
        ],
        trackName: '十年',
        artistName: '',
        duration: 0,
      );
      expect(picked, isNotNull);
    });

    test('strict 必须有歌手命中', () {
      final picked = pickTranslatableSong(
        [
          song(name: '十年', artists: ['别人'], durationMs: 300000),
        ],
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
        strict: true,
      );
      expect(picked, isNull);
      // 歌手命中时 strict 也放行
      expect(
        pickTranslatableSong(
          [
            song(name: '十年', artists: ['陈奕迅'], durationMs: 0),
          ],
          trackName: '十年',
          artistName: '陈奕迅',
          duration: 300,
          strict: true,
        ),
        isNotNull,
      );
      // 别名全等（titleExact）但歌手不命中 → strict 照样淘汰
      expect(
        pickTranslatableSong(
          [
            song(name: 'Ten Years', alias: ['十年'], artists: ['别人']),
          ],
          trackName: '十年',
          artistName: '陈奕迅',
          duration: 300,
          strict: true,
        ),
        isNull,
      );
    });

    test('wantTitle 为空 → null', () {
      expect(
        pickTranslatableSong(
          [song()],
          trackName: '',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
      // 纯空白归一化后也是空
      expect(
        pickTranslatableSong(
          [song()],
          trackName: '   ',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
    });

    test('同分取靠前的（score > bestScore 严格大于）', () {
      final first = song(
        id: 1,
        name: '十年',
        artists: ['别人'],
        durationMs: 300000,
      );
      final second = song(
        id: 2,
        name: '十年',
        artists: ['别人'],
        durationMs: 300000,
      );
      final picked = pickTranslatableSong(
        [first, second],
        trackName: '十年',
        artistName: '',
        duration: 300,
      );
      expect(picked!.id, 1);
    });

    test('同分保留先出现的：名字全等+歌手 与 名字全等+时长 都是 65 分', () {
      final byArtist = song(id: 7, name: '十年', artists: ['陈奕迅'], durationMs: 0);
      final byDuration = song(
        id: 8,
        name: '十年',
        artists: ['别人'],
        durationMs: 300000,
      );
      final picked = pickTranslatableSong(
        [byArtist, byDuration],
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked!.id, 7);
    });

    test('后面分数更高会替换掉前面的', () {
      // 1 号：前缀命中 + 歌手命中 = 18 + 25 = 43
      // 2 号：名字全等 + 时长命中 = 40 + 25 = 65
      final picked = pickTranslatableSong(
        [
          song(
            id: 1,
            name: 'Yellow Live',
            artists: ['Coldplay'],
            durationMs: 320000,
          ),
          song(id: 2, name: 'Yellow', artists: ['别人'], durationMs: 300000),
        ],
        trackName: 'Yellow',
        artistName: 'Coldplay',
        duration: 300,
      );
      expect(picked!.id, 2);
    });

    test('id 为 0 / 空名字跳过', () {
      expect(
        pickTranslatableSong(
          [song(id: 0)],
          trackName: '十年',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
      expect(
        pickTranslatableSong(
          [song(name: '')],
          trackName: '十年',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
    });

    test('空搜索结果 → null', () {
      expect(
        pickTranslatableSong(
          const [],
          trackName: '十年',
          artistName: '',
          duration: 0,
        ),
        isNull,
      );
    });
  });

  group('translatePairs', () {
    test('原方向 → 对调（strict）→ 拆头 → 拆尾，各就各位', () {
      // 两侧各 2 字符才拆得动（.{2,60}）；'甲 - 乙' 两侧各 1 字符不拆，
      // brief 原期望用它产出 4 条与 JS 实测不符（parity 校正）
      final pairs = translatePairs('甲乙 - 丙丁', '戊');
      expect(pairs.map((p) => (p.name, p.artist, p.strict)), [
        ('甲乙 - 丙丁', '戊', false),
        ('戊', '甲乙 - 丙丁', true),
        ('甲乙', '丙丁', true),
        ('丙丁', '甲乙', true),
      ]);
    });

    test('拆出来的 pair 里 artist 排在 name 前面时也不重复', () {
      // artist 恰好等于拆出的尾段：第 2 条与第 4 条同名不同侧，都保留
      final pairs = translatePairs('甲乙 - 丙丁', '丙丁');
      expect(pairs.map((p) => (p.name, p.artist, p.strict)), [
        ('甲乙 - 丙丁', '丙丁', false),
        ('丙丁', '甲乙 - 丙丁', true),
        ('甲乙', '丙丁', true),
        ('丙丁', '甲乙', true),
      ]);
    });

    test('歌手为空或等于曲名时不加对调', () {
      expect(translatePairs('十年', '').length, 1);
      expect(translatePairs('十年', '十年').length, 1);
    });

    test('拆分要求破折号两侧都有空白，且两侧各 2~60 字符', () {
      expect(translatePairs('Jay-Z', '').length, 1);
      expect(translatePairs('A - B', '').length, 1); // 两侧各 1 字符，不拆
      expect(translatePairs('甲 - 乙', '').length, 1); // 同上（brief 原以为会拆）
      expect(translatePairs('ab - cd', '').length, 3); // 两侧各 2 字符，拆
      // 破折号两侧都要空白：连写的不拆；全角空格也算空白
      expect(translatePairs('ab–cd', '').length, 1);
      expect(translatePairs('ab—cd', '').length, 1);
      expect(translatePairs('ab — cd', '').length, 3);
      expect(translatePairs('ab　-　cd', '').length, 3);
      // 60 字符上限：61 字符那侧不拆
      expect(translatePairs('${'x' * 60} - 丙丁', '').length, 3);
      expect(translatePairs('${'x' * 61} - 丙丁', '').length, 1);
    });

    test('破折号是惰性匹配：只按第一个破折号拆', () {
      expect(
        translatePairs('ab - cd - ef', '').map((p) => (p.name, p.artist)),
        [('ab - cd - ef', ''), ('ab', 'cd - ef'), ('cd - ef', 'ab')],
      );
    });

    test('按 name|artist 小写去重，保留首次出现的顺序', () {
      // head 与 tail 相同时，第 3 条与第 2 条完全重复 → 去掉
      expect(translatePairs('abcd - abcd', '').length, 2);
      // 去重的键是小写：'ab' 与 'AB' 视为同一条
      expect(translatePairs('ab - AB', '').map((p) => (p.name, p.artist)), [
        ('ab - AB', ''),
        ('ab', 'AB'),
      ]);
      final pairs = translatePairs('甲乙 - 丙丁', '戊');
      final keys = pairs
          .map((p) => '${p.name}|${p.artist}'.toLowerCase())
          .toSet();
      expect(keys.length, pairs.length);
    });

    test('空 trackName 也照原样产出两条（artist 非空时）', () {
      final pairs = translatePairs('', '甲');
      expect(pairs.map((p) => (p.name, p.artist, p.strict)), [
        ('', '甲', false),
        ('甲', '', true),
      ]);
    });

    test('keyword 是「歌手 曲名」，空侧省略', () {
      expect(
        const TranslateCandidate(
          name: '十年',
          artist: '陈奕迅',
          strict: false,
        ).keyword,
        '陈奕迅 十年',
      );
      expect(
        const TranslateCandidate(name: '十年', artist: '', strict: false).keyword,
        '十年',
      );
      expect(
        const TranslateCandidate(name: '', artist: '', strict: false).keyword,
        '',
      );
    });
  });

  group('parseNetEaseSong', () {
    test('脏数据一律 null，不抛', () {
      expect(parseNetEaseSong(null), isNull);
      expect(parseNetEaseSong('x'), isNull);
      expect(parseNetEaseSong(42), isNull);
      expect(parseNetEaseSong(const []), isNull);
      // 缺 id / id 非正 / id 非整数
      expect(parseNetEaseSong(const {'name': '十年'}), isNull);
      expect(parseNetEaseSong(const {'id': 0, 'name': '十年'}), isNull);
      expect(parseNetEaseSong(const {'id': -1, 'name': '十年'}), isNull);
      expect(parseNetEaseSong(const {'id': '1', 'name': '十年'}), isNull);
      expect(parseNetEaseSong(const {'id': 1.5, 'name': '十年'}), isNull);
    });

    test('正常字段照取，缺失字段给默认值', () {
      final parsed = parseNetEaseSong(const {
        'id': 123,
        'name': '十年',
        'duration': 300000,
        'artists': [
          {'name': '陈奕迅'},
        ],
        'alias': ['十年'],
      });
      expect(parsed, isNotNull);
      expect(parsed!.id, 123);
      expect(parsed.name, '十年');
      expect(parsed.durationMs, 300000);
      expect(parsed.artists, ['陈奕迅']);
      expect(parsed.alias, ['十年']);

      final bare = parseNetEaseSong(const {'id': 5});
      expect(bare!.name, '');
      expect(bare.durationMs, 0);
      expect(bare.artists, isEmpty);
      expect(bare.alias, isEmpty);
    });

    test('类型不对的字段退回默认值，不抛', () {
      final parsed = parseNetEaseSong(const {
        'id': 5,
        'name': 3,
        'duration': '300000',
        'artists': '陈奕迅',
        'alias': '十年',
      });
      expect(parsed!.name, '');
      expect(parsed.durationMs, 0);
      expect(parsed.artists, isEmpty);
      expect(parsed.alias, isEmpty);
    });

    test('artists 只收 Map 里的非空 name；alias 只收 String', () {
      final parsed = parseNetEaseSong(const {
        'id': 5,
        'artists': [
          {'name': '甲'},
          {'name': 3},
          {'id': 1},
          '乙',
          null,
          {'name': ''},
        ],
        'alias': ['十年', 3, null],
      });
      expect(parsed!.artists, ['甲']);
      expect(parsed.alias, ['十年']);
    });

    test('id 为 5.0（JSON 数字可能解成 double）也接受', () {
      expect(parseNetEaseSong(const {'id': 5.0})!.id, 5);
    });
  });

  group('parseNetEaseSongs', () {
    test('读 result.songs，非数组 / 非 Map 给空', () {
      expect(parseNetEaseSongs(null), isEmpty);
      expect(parseNetEaseSongs(const []), isEmpty);
      expect(parseNetEaseSongs(const {}), isEmpty);
      expect(parseNetEaseSongs(const {'result': null}), isEmpty);
      expect(parseNetEaseSongs(const {'result': []}), isEmpty);
      expect(
        parseNetEaseSongs(const {
          'result': {'songs': 'x'},
        }),
        isEmpty,
      );
      expect(
        parseNetEaseSongs(const {
          'result': {'songs': <Object?>[]},
        }),
        isEmpty,
      );
    });

    test('逐条解析并丢掉脏条目', () {
      final songs = parseNetEaseSongs(const {
        'result': {
          'songs': [
            {'id': 1, 'name': '甲'},
            {'id': 0, 'name': '乙'},
            null,
            'x',
            {'id': 2, 'name': '丙'},
          ],
        },
      });
      expect(songs.map((s) => s.id), [1, 2]);
    });

    test('脏条目混在搜索结果里不影响整次匹配', () {
      // 一条怪数据不该让整次认歌失败（parse 只丢它自己）
      final songs = parseNetEaseSongs(const {
        'result': {
          'songs': [
            {'id': 'oops'},
            {
              'id': 9,
              'name': '十年',
              'duration': 300000,
              'artists': [
                {'name': '陈奕迅'},
              ],
            },
          ],
        },
      });
      final picked = pickTranslatableSong(
        songs,
        trackName: '十年',
        artistName: '陈奕迅',
        duration: 300,
      );
      expect(picked!.id, 9);
    });
  });
}
