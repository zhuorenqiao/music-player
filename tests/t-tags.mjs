/**
 * t-tags.mjs —— src/lib/audio-tags.js 的字节级单元测试（Node 直接跑，不需要浏览器）
 *
 * 做法：手工拼出各格式的标签字节，喂给 readAudioTags，断言解出来的字段。
 * 覆盖：ID3v2.3 / ID3v2.4（synchsafe + unsync）/ ID3v1 兜底 / FLAC / OGG / M4A / 畸形输入。
 *
 * 运行：node tests/t-tags.mjs
 */

import { readAudioTags, mergeTaggedNames } from '../src/lib/audio-tags.js';

let passed = 0;
let failed = 0;

function check(label, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    passed += 1;
  } else {
    failed += 1;
    console.log(`  FAIL ${label}\n       期望 ${JSON.stringify(expected)}\n       实际 ${JSON.stringify(actual)}`);
  }
}

function ok(label, condition, detail = '') {
  if (condition) {
    passed += 1;
  } else {
    failed += 1;
    console.log(`  FAIL ${label} ${detail}`);
  }
}

// ---------------------------------------------------------------------------
// 字节构造工具
// ---------------------------------------------------------------------------

const enc = new TextEncoder();

function bytes(...parts) {
  const chunks = parts.map((part) => (part instanceof Uint8Array ? part : new Uint8Array(part)));
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

const u32be = (n) => new Uint8Array([(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff]);
const u32le = (n) => new Uint8Array([n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff]);
const synchsafe = (n) => new Uint8Array([(n >>> 21) & 0x7f, (n >>> 14) & 0x7f, (n >>> 7) & 0x7f, n & 0x7f]);
const fourcc = (s) => enc.encode(s);
const latin1 = (s) => Uint8Array.from([...s], (c) => c.charCodeAt(0) & 0xff);
const cstr = (s) => bytes(enc.encode(s), [0]);
const PNG = bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

/** ID3v2 文本帧。encoding: 0 latin1 / 1 utf-16 / 3 utf-8 */
function textFrame(id, value, encoding = 3, version = 3) {
  let payload;
  if (encoding === 1) {
    const le = new Uint8Array([...Buffer.from(value, 'utf16le')]);
    payload = bytes([1], [0xff, 0xfe], le);
  } else if (encoding === 0) {
    payload = bytes([0], latin1(value));
  } else {
    payload = bytes([3], enc.encode(value));
  }
  const sizeField = version === 4 ? synchsafe(payload.length) : u32be(payload.length);
  return bytes(fourcc(id), sizeField, [0, 0], payload);
}

/** APIC 帧（v2.3/2.4 布局）。 */
function apicFrame(mime, picture, { coverType = 3, description = '', encoding = 3, version = 3 } = {}) {
  const head = encoding === 1
    ? bytes([1], latin1(mime), [0], [coverType], ...[Buffer.from(description, 'utf16le'), new Uint8Array([0, 0])].map((x) => x))
    : bytes([encoding], latin1(mime), [0], [coverType], latin1(description), [0]);
  const payload = bytes(head, picture);
  const sizeField = version === 4 ? synchsafe(payload.length) : u32be(payload.length);
  return bytes(fourcc('APIC'), sizeField, [0, 0], payload);
}

function id3v2(frames, { version = 3, flags = 0 } = {}) {
  const body = bytes(...frames);
  return bytes(fourcc('ID3'), [version, 0, flags], synchsafe(body.length), body);
}

/** 一小段 MPEG 音频帧，模拟 ID3 之后的真实数据。 */
const MPEG_FRAME = bytes([0xff, 0xfb, 0x90, 0x64], new Uint8Array(400));

function blobOf(file) {
  return new Blob([file], { type: 'audio/mpeg' });
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

const results = [];

async function run(label, file, assertions) {
  const tags = await readAudioTags(file);
  const got = {
    format: tags.format,
    title: tags.title,
    artist: tags.artist,
    album: tags.album,
    albumArtist: tags.albumArtist,
    year: tags.year,
    picture: tags.picture ? { type: tags.picture.type, size: tags.picture.blob.size, coverType: tags.picture.coverType } : null,
  };
  let allOk = true;
  for (const [key, expected] of Object.entries(assertions)) {
    const actual = key === 'picture' ? got.picture?.[expected.k] : got[key];
    const value = key === 'picture' ? got.picture?.[expected.k] : got[key];
    const okNow = key === 'picture' ? value === expected.v : value === expected;
    if (!okNow) {
      allOk = false;
      failed += 1;
      console.log(`  FAIL ${label} · ${key}\n       期望 ${JSON.stringify(expected)}\n       实际 ${JSON.stringify(actual)}`);
    } else {
      passed += 1;
    }
  }
  results.push({ label, ok: allOk, got });
  return got;
}

console.log('\n== ID3v2.3（中文 UTF-16 标题 + 内嵌 PNG 封面）==');
await run('id3v23', blobOf(bytes(
  id3v2([
    textFrame('TIT2', '光年之外', 1),
    textFrame('TPE1', 'G.E.M. 邓紫棋', 1),
    textFrame('TALB', '另一个城市', 3),
    textFrame('TPE2', 'G.E.M.', 3),
    textFrame('TYER', '2016', 3),
    apicFrame('image/png', PNG),
  ]),
  MPEG_FRAME,
)), {
  format: 'mp3',
  title: '光年之外',
  artist: 'G.E.M. 邓紫棋',
  album: '另一个城市',
  albumArtist: 'G.E.M.',
  year: '2016',
  picture: { k: 'type', v: 'image/png' },
});

console.log('== ID3v2.4（synchsafe 帧长 + 整标签 unsync：0xFF 0x00 需要还原）==');
const unsyncBody = bytes(
  textFrame('TIT2', 'Unsync 测试', 3, 4),
  apicFrame('image/png', bytes([0xff, 0x00, 0xd8, 0xff, 0xe0]), { version: 4 }), // 故意放 JPEG+0xFF 0x00
);
await run('id3v24-unsync', blobOf(bytes(
  fourcc('ID3'), [4, 0, 0x80], synchsafe(unsyncBody.length), unsyncBody, MPEG_FRAME,
)), {
  format: 'mp3',
  title: 'Unsync 测试',
});

console.log('== 只有 ID3v1（尾部 128 字节 TAG）==');
const id3v1 = bytes(
  fourcc('TAG'),
  latin1('Yellow Submarine'.padEnd(30)),
  latin1('The Beatles'.padEnd(30)),
  latin1('Revolver'.padEnd(30)),
  latin1('1966'),
  new Uint8Array(31),
);
await run('id3v1', blobOf(bytes(MPEG_FRAME, id3v1)), {
  format: 'mp3',
  title: 'Yellow Submarine',
  artist: 'The Beatles',
  album: 'Revolver',
  year: '1966',
});

console.log('== FLAC（Vorbis Comment + PICTURE 块）==');
function vorbisComment(entries) {
  const vendor = cstr('test-tagging');
  const lines = entries.map((line) => bytes(u32le(enc.encode(line).length), enc.encode(line)));
  return bytes(u32le(vendor.length), vendor, u32le(entries.length), ...lines);
}
function flacPictureBlock(picture, { coverType = 3, mime = 'image/png' } = {}) {
  const m = latin1(mime);
  return bytes(
    u32be(coverType), u32be(m.length), m,
    u32be(0), // 描述长度
    u32be(120), u32be(120), u32be(24), u32be(0),
    u32be(picture.length), picture,
  );
}
const streaminfo = new Uint8Array(34);
/** FLAC 元数据块：1 字节（last-flag | type）+ 3 字节大端长度 + 内容 */
function metaBlock(type, content) {
  return bytes([type], u32be(content.length).subarray(1), content);
}
const flac = bytes(
  fourcc('fLaC'),
  metaBlock(0x00, streaminfo),
  metaBlock(0x04, vorbisComment(['TITLE=夜曲', 'ARTIST=周杰伦', 'ALBUM=十一月的萧邦', 'DATE=2005', 'ALBUMARTIST=周杰伦'])),
  metaBlock(0x86, flacPictureBlock(PNG)),
  new Uint8Array(64),
);
await run('flac', new Blob([flac], { type: 'audio/flac' }), {
  format: 'flac',
  title: '夜曲',
  artist: '周杰伦',
  album: '十一月的萧邦',
  year: '2005',
  albumArtist: '周杰伦',
  picture: { k: 'type', v: 'image/png' },
});

console.log('== M4A（ftyp + moov.udta.meta.ilst：©nam / ©ART / covr）==');
function mp4Box(type, ...payloadParts) {
  const typeBytes = typeof type === 'string' ? fourcc(type) : type;
  const payload = bytes(...payloadParts);
  return bytes(u32be(payload.length + 8), typeBytes, payload);
}
function dataAtom(payload, flags = 1) {
  return bytes(u32be(payload.length + 16), fourcc('data'), u32be(flags), u32be(0), payload);
}
const m4a = bytes(
  mp4Box('ftyp', fourcc('M4A '), u32be(0), fourcc('M4A ')),
  mp4Box('moov',
    mp4Box('mvhd', new Uint8Array(100)),
    mp4Box('udta',
      mp4Box('meta', u32be(0),
        mp4Box('ilst',
          // iTunes 的 © 是 latin-1 单字节 0xA9，用 UTF-8 编码会变成两字节
          mp4Box(latin1('©nam'), dataAtom(enc.encode('稻香'))),
          mp4Box(latin1('©ART'), dataAtom(enc.encode('周杰伦'))),
          mp4Box(latin1('©alb'), dataAtom(enc.encode('魔杰座'))),
          mp4Box('covr', dataAtom(PNG, 13)),
        ),
      ),
    ),
  ),
);
await run('m4a', new Blob([m4a], { type: 'audio/mp4' }), {
  format: 'm4a',
  title: '稻香',
  artist: '周杰伦',
  album: '魔杰座',
  picture: { k: 'type', v: 'image/png' },
});

console.log('== OGG（Vorbis comment + base64 METADATA_BLOCK_PICTURE）==');
const oggComment = bytes([0x03], fourcc('vorbis'), vorbisComment([
  'TITLE=大鱼', 'ARTIST=周深', 'ALBUM=深的深',
  `METADATA_BLOCK_PICTURE=${Buffer.from(flacPictureBlock(PNG)).toString('base64')}`,
]));
const oggIdent = bytes([0x01], fourcc('vorbis'), new Uint8Array(40));
function oggPacket(payload) {
  // 简化页：OggS + 版本 + 头标志(0x02=BOS) + 64 位序号 + 校验 + serial + 序号 + 段表
  const segments = [Math.floor(payload.length / 255)];
  const header = bytes(
    fourcc('OggS'), [0], [0x02], new Uint8Array(8), new Uint8Array(4), u32le(1), new Uint8Array(4),
    [segments[0]],
  );
  return bytes(header, payload);
}
const ogg = bytes(oggPacket(oggIdent), oggPacket(oggComment), new Uint8Array(32));
await run('ogg', new Blob([ogg], { type: 'audio/ogg' }), {
  format: 'ogg',
  title: '大鱼',
  artist: '周深',
  album: '深的深',
  picture: { k: 'type', v: 'image/png' },
});

console.log('== 畸形 / 边界输入：不许抛异常 ==');
for (const [label, data] of [
  ['空文件', new Uint8Array(0)],
  ['随机字节', new Uint8Array(Array.from({ length: 500 }, (_, i) => (i * 37) % 251))],
  ['ID3 声明超大帧区', bytes(fourcc('ID3'), [4, 0, 0], synchsafe(9_000_000), new Uint8Array(100))],
  ['fLaC 但块长度爆炸', bytes(fourcc('fLaC'), [0x04], [0xff, 0xff, 0xff], new Uint8Array(8))],
  ['MP4 有 ftyp 无 moov', mp4Box('ftyp', fourcc('M4A '), u32be(0))],
  ['APIC mime 为空（靠魔数嗅探）', bytes(id3v2([apicFrame('', bytes([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]))]), MPEG_FRAME)],
]) {
  const tags = await readAudioTags(new Blob([data]));
  ok(`${label} 不抛异常`, typeof tags.format === 'string', JSON.stringify(tags));
  if (label.startsWith('APIC')) {
    check('嗅探出 JPEG', tags.picture?.type, 'image/jpeg');
  }
}

console.log('== mergeTaggedNames：标签优先、文件名兜底 ==');
check('标签齐全时忽略文件名', mergeTaggedNames({ title: 'A', artist: 'B' }, { title: 'X', artist: 'Y' }), { title: 'A', artist: 'B', usedTags: true });
check('只有曲名标签', mergeTaggedNames({ title: 'A' }, { title: 'X', artist: 'Y' }), { title: 'A', artist: 'Y', usedTags: true });
check('albumArtist 兜 artist', mergeTaggedNames({ artist: '', albumArtist: 'B' }, { title: 'X', artist: 'Y' }), { title: 'X', artist: 'B', usedTags: true });
check('完全无标签', mergeTaggedNames({}, { title: 'X', artist: 'Y' }), { title: 'X', artist: 'Y', usedTags: false });

console.log(`\n通过 ${passed} · 失败 ${failed}\n`);
process.exit(failed === 0 ? 0 : 1);
