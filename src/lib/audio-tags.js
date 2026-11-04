/**
 * audio-tags.js —— 读取音频文件内嵌元数据（真正的「自动分析」）
 *
 * 为什么需要：导入时只靠文件名猜「歌手 - 歌名」，遇到「唯一.mp3」「01.flac」
 * 这种命名就完全没救。而绝大多数正版/抓取音频文件本身带着标签：
 *   - MP3 / 其他以 ID3v2 打头的文件：TIT2 曲名、TPE1 歌手、TALB 专辑、APIC 内嵌封面
 *   - FLAC：Vorbis Comment（TITLE/ARTIST/ALBUM）+ PICTURE 块
 *   - OGG：同一套 Vorbis Comment，封面是 base64 的 METADATA_BLOCK_PICTURE
 *   - M4A / MP4：moov.udta.meta.ilst 里的 ©nam / ©ART / ©alb / covr
 * 内嵌封面是**这张专辑的官方图**，比任何在线匹配都准，所以它排在链路最前面。
 *
 * 只读需要的那段字节（头部 64KB 判断格式，标签区按需再读），不会把整首歌读进内存。
 * 全部接口不抛异常：解析失败就返回能拿到的部分，由调用方决定继续走哪条兜底。
 * 本模块不碰 DOM。
 */

/** 判断格式时先读的字节数。 */
const PROBE_BYTES = 64 * 1024;

/** 标签区（含内嵌封面）最多读这么多，防止畸形长度把内存吃光。 */
const MAX_TAG_BYTES = 8 * 1024 * 1024;

/** 单张内嵌封面的字节上限，超了当作不可用。 */
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 字节工具
// ---------------------------------------------------------------------------

/**
 * 读取文件的某一段。
 * @param {File|Blob} file 文件
 * @param {number} start 起始偏移
 * @param {number} length 期望长度（自动裁到文件末尾与上限之间）
 * @returns {Promise<Uint8Array>} 实际读到的字节（可能短于 length）
 */
async function readSlice(file, start, length) {
  const from = Math.max(0, start);
  const to = Math.min(file.size, from + Math.max(0, length));
  if (to <= from) {
    return new Uint8Array(0);
  }
  const buffer = await file.slice(from, to).arrayBuffer();
  return new Uint8Array(buffer);
}

/**
 * 把字节按指定编码解成字符串（解不出来退回空串，绝不抛）。
 * @param {Uint8Array} bytes 原始字节
 * @param {string} encoding TextDecoder 能认的编码名
 * @returns {string}
 */
function decodeText(bytes, encoding) {
  try {
    return new TextDecoder(encoding, { fatal: false }).decode(bytes);
  } catch (error) {
    console.error('[audio-tags] 文本解码失败：', encoding, error);
    return '';
  }
}

/**
 * 字节能否按某种编码严格解开（遇到非法序列直接抛错）。
 * @param {Uint8Array} bytes 原始字节
 * @param {string} encoding 编码名
 * @returns {boolean}
 */
function canDecodeStrictly(bytes, encoding) {
  try {
    new TextDecoder(encoding, { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

/**
 * 是否出现「连续两个以上高位字节」。
 * GBK 的汉字 / 全角符号都是双字节且两字节都 ≥0x80，成串出现；
 * 真正的西文 Latin-1（Motörhead、Café）重音字母是孤立的，
 * 用这个特征把「恰好也是合法 GBK 的拉丁文」挡在 GBK 之外。
 * @param {Uint8Array} bytes 文本字节
 * @returns {boolean}
 */
function hasHighByteRun(bytes) {
  let run = 0;
  for (let i = 0; i < bytes.length; i += 1) {
    if (bytes[i] >= 0x80) {
      run += 1;
      if (run >= 2) {
        return true;
      }
    } else {
      run = 0;
    }
  }
  return false;
}

/**
 * 解码「编码声明不可信」的文本。
 *
 * 中文音频文件的标签大量不符合规范：ID3v1 压根没有编码位，老工具一律按
 * GBK 写；ID3v2 的 encoding=0（名义 ISO-8859-1）有的工具塞 GBK，有的工具
 * 塞 UTF-8。盲信声明就会解出「Ò¹Çú」「å¤œæ›²」这类乱码。
 * 所以按 ASCII → UTF-8 → GBK（需有高位字节串）嗅探，都不成立才用
 * Latin-1 兜底 —— 西文重音字母不会被误判成汉字。
 * @param {Uint8Array} bytes 文本字节（不含 encoding 字节）
 * @returns {string}
 */
function decodeLegacyText(bytes) {
  if (!bytes || bytes.length === 0) {
    return '';
  }
  let ascii = true;
  for (let i = 0; i < bytes.length; i += 1) {
    if (bytes[i] >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) {
    return decodeText(bytes, 'utf-8');
  }
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return decodeText(bytes.subarray(3), 'utf-8');
  }
  if (canDecodeStrictly(bytes, 'utf-8')) {
    return decodeText(bytes, 'utf-8');
  }
  if (hasHighByteRun(bytes) && canDecodeStrictly(bytes, 'gbk')) {
    return decodeText(bytes, 'gbk');
  }
  return decodeText(bytes, 'iso-8859-1');
}

/**
 * 判断某偏移处是否是指定字节序列。
 * @param {Uint8Array} view 数据
 * @param {number} offset 偏移
 * @param {number[]} signature 期望字节
 * @returns {boolean}
 */
function matchAt(view, offset, signature) {
  if (offset < 0 || offset + signature.length > view.length) {
    return false;
  }
  return signature.every((byte, index) => view[offset + index] === byte);
}

/**
 * 按 ASCII 比较某段字节（MP4 的 fourcc 都用这个）。
 * @param {Uint8Array} view 数据
 * @param {number} offset 偏移
 * @param {string} text 期望的 4 字符
 * @returns {boolean}
 */
function matchText(view, offset, text) {
  const bytes = new Uint8Array([...text].map((char) => char.charCodeAt(0)));
  return matchAt(view, offset, [...bytes]);
}

/** 大端 uint32。 */
function readU32BE(view, offset) {
  if (offset + 4 > view.length) {
    return 0;
  }
  return ((view[offset] << 24) | (view[offset + 1] << 16) | (view[offset + 2] << 8) | view[offset + 3]) >>> 0;
}

/** 小端 uint32。 */
function readU32LE(view, offset) {
  if (offset + 4 > view.length) {
    return 0;
  }
  return (view[offset] | (view[offset + 1] << 8) | (view[offset + 2] << 16) | (view[offset + 3] << 24)) >>> 0;
}

/** ID3v2 的 synchsafe 整数（每字节只用 7 位）。 */
function readSynchsafe(view, offset) {
  return (
    ((view[offset] & 0x7f) << 21)
    | ((view[offset + 1] & 0x7f) << 14)
    | ((view[offset + 2] & 0x7f) << 7)
    | (view[offset + 3] & 0x7f)
  );
}

/** 去掉字符串里的 NUL、首尾空白与控制字符。 */
function cleanText(value) {
  return String(value ?? '')
    .replace(/\u0000/g, '')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .trim();
}

/**
 * 按帧的 encoding 字节解文本（0 latin1 / 1 utf-16 / 2 utf-16be / 3 utf-8）。
 * @param {Uint8Array} bytes 帧内容（不含 encoding 字节）
 * @param {number} encoding ID3 的文本编码号
 * @returns {string}
 */
function decodeId3Text(bytes, encoding) {
  if (encoding === 1) {
    // 带 BOM 的 UTF-16；没有 BOM 时按 UTF-16LE 猜（写标签的工具绝大多数用 LE）
    const hasBom = bytes[0] === 0xff && bytes[1] === 0xfe;
    return decodeText(hasBom ? bytes.subarray(2) : bytes, hasBom ? 'utf-16le' : 'utf-16le');
  }
  if (encoding === 2) {
    return decodeText(bytes, 'utf-16be');
  }
  if (encoding === 3) {
    return decodeText(bytes, 'utf-8');
  }
  // encoding=0 名义上是 ISO-8859-1，但中文文件常被写成 GBK / UTF-8
  return decodeLegacyText(bytes);
}

/**
 * 取消 ID3 的 unsynchronisation（0xFF 0x00 还原成 0xFF），只在整标签或整帧被标记时用。
 * @param {Uint8Array} bytes 原始字节
 * @returns {Uint8Array}
 */
function desynchronise(bytes) {
  const out = new Uint8Array(bytes.length);
  let written = 0;
  for (let i = 0; i < bytes.length; i += 1) {
    out[written] = bytes[i];
    written += 1;
    // 跳过紧跟 0xFF 的填充 0x00
    if (bytes[i] === 0xff && bytes[i + 1] === 0x00) {
      i += 1;
    }
  }
  return out.subarray(0, written);
}

// ---------------------------------------------------------------------------
// ID3v2（MP3 及以 ID3 打头的其它文件）
// ---------------------------------------------------------------------------

/**
 * 解析 ID3v2.2/2.3/2.4 标签。
 * @param {Uint8Array} tag 从帧区开始的完整标签字节（不含 10 字节头）
 * @param {number} version 主版本号（2 / 3 / 4）
 * @param {number} flags 头部的 flags 字节
 * @returns {{title: string, artist: string, album: string, albumArtist: string, year: string, picture: {blob: Blob, type: string}|null}}
 */
function parseId3v2Frames(tag, version, flags) {
  const result = { title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
  const unsyncAll = (flags & 0x80) !== 0;
  const body = unsyncAll ? desynchronise(tag) : tag;

  // v2.3 有扩展头（flag 0x40）：4 字节扩展长度 + 扩展标志，帧区整体后移
  let cursor = 0;
  if (version === 3 && (flags & 0x40) !== 0) {
    cursor = 4 + readU32BE(body, 4);
  }

  const idLength = version === 2 ? 3 : 4;
  const headerLength = idLength + 4 + 2;

  while (cursor + headerLength <= body.length) {
    const id = decodeText(body.subarray(cursor, cursor + idLength), 'iso-8859-1');
    if (!/^[A-Z0-9@©]{3,4}$/.test(id)) {
      break; // 进了 padding 区
    }

    const sizeField = body.subarray(cursor + idLength, cursor + idLength + 4);
    // v2.4 的帧长度是 synchsafe，v2.2/2.3 是普通大端
    const frameSize = version === 4 ? readSynchsafe(sizeField, 0) : readU32BE(sizeField, 0);
    if (frameSize <= 0 || cursor + headerLength + frameSize > body.length) {
      break;
    }
    const frameFlags = version === 2 ? 0 : (sizeField[0], body[cursor + idLength + 4]);
    let content = body.subarray(cursor + headerLength, cursor + headerLength + frameSize);
    // v2.4 允许单帧自带 unsync（flags 的第 1 字节 0x02）
    if (version === 4 && (frameFlags & 0x02) !== 0) {
      content = desynchronise(content);
    }

    const encoding = content[0] ?? 0;
    if (id === 'TIT2' || (version === 2 && id === 'TT2')) {
      result.title ||= cleanText(decodeId3Text(content.subarray(1), encoding));
    } else if (id === 'TPE1' || (version === 2 && id === 'TP1')) {
      result.artist ||= cleanText(decodeId3Text(content.subarray(1), encoding));
    } else if (id === 'TALB' || (version === 2 && id === 'TAL')) {
      result.album ||= cleanText(decodeId3Text(content.subarray(1), encoding));
    } else if (id === 'TPE2' || (version === 2 && id === 'TP2')) {
      result.albumArtist ||= cleanText(decodeId3Text(content.subarray(1), encoding));
    } else if (id === 'TYER' || id === 'TDRC' || (version === 2 && id === 'TYE')) {
      const raw = cleanText(decodeId3Text(content.subarray(1), encoding));
      result.year ||= (raw.match(/\d{4}/) ?? [''])[0];
    } else if (id === 'APIC' || (version === 2 && id === 'PIC')) {
      const picture = parseApicFrame(content, version, id === 'PIC');
      // 优先封面类型（type 3），没有就留第一张
      if (picture && (!result.picture || picture.coverType === 3)) {
        result.picture = picture;
      }
    }

    cursor += headerLength + frameSize;
  }

  return result;
}

/**
 * 解析 APIC / PIC 帧。
 * @param {Uint8Array} content 帧内容
 * @param {number} version ID3 主版本
 * @param {boolean} isV2Pic v2.2 的 PIC 帧：mime 是 3 字符固定码而非空结尾字符串
 * @returns {{blob: Blob, type: string, coverType: number}|null}
 */
function parseApicFrame(content, version, isV2Pic) {
  if (content.length < 4) {
    return null;
  }
  let offset = 1; // 跳过 encoding 字节
  let mime = '';
  if (isV2Pic) {
    // v2.2 存的是 'JPG' / 'PNG' 这类图片格式码
    const code = decodeText(content.subarray(offset, offset + 3), 'iso-8859-1').toUpperCase();
    mime = code === 'PNG' ? 'image/png' : 'image/jpeg';
    offset += 3;
  } else {
    const end = content.indexOf(0x00, offset);
    if (end < 0) {
      return null;
    }
    mime = cleanText(decodeText(content.subarray(offset, end), 'iso-8859-1')).toLowerCase();
    offset = end + 1;
  }

  const coverType = content[offset] ?? 0;
  offset += 1;

  // 描述文字按帧编码解，结束符随编码而变（UTF-16 是双 NUL）
  const encoding = content[0];
  const descriptionEnd = findTerminator(content, offset, encoding === 1 || encoding === 2);
  if (descriptionEnd < 0) {
    return null;
  }
  offset = descriptionEnd + (encoding === 1 || encoding === 2 ? 2 : 1);

  const data = content.subarray(offset);
  if (data.length === 0 || data.length > MAX_IMAGE_BYTES) {
    return null;
  }
  if (!/^image\//.test(mime)) {
    mime = sniffImageMime(data) ?? '';
  }
  if (!mime) {
    return null;
  }
  // 复制一份：content 是整个标签的视图，直接引用会把整块内存挂在 Blob 上
  return { blob: new Blob([Uint8Array.prototype.slice.call(data)], { type: mime }), type: mime, coverType };
}

/**
 * 找帧内的字符串结束符。
 * @param {Uint8Array} bytes 数据
 * @param {number} from 起始偏移
 * @param {boolean} wide UTF-16（双字节 NUL 结尾）
 * @returns {number} 结束符位置，找不到返回 -1
 */
function findTerminator(bytes, from, wide) {
  for (let i = from; i < bytes.length; i += 1) {
    if (bytes[i] !== 0x00) {
      continue;
    }
    if (!wide) {
      return i;
    }
    if (bytes[i + 1] === 0x00) {
      return i;
    }
  }
  return -1;
}

/**
 * 按魔数识别图片类型（有些文件的 APIC mime 写错或留空）。
 * @param {Uint8Array} bytes 图片字节
 * @returns {string|null}
 */
function sniffImageMime(bytes) {
  if (matchAt(bytes, 0, [0x89, 0x50, 0x4e, 0x47])) {
    return 'image/png';
  }
  if (matchAt(bytes, 0, [0xff, 0xd8, 0xff])) {
    return 'image/jpeg';
  }
  if (matchAt(bytes, 0, [0x47, 0x49, 0x46, 0x38])) {
    return 'image/gif';
  }
  if (matchAt(bytes, 0, [0x52, 0x49, 0x46, 0x46]) && matchAt(bytes, 8, [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return null;
}

/**
 * 解析尾部 128 字节的 ID3v1（老 MP3 常有，字段很短但聊胜于无）。
 * @param {Uint8Array} tail 文件末尾字节
 * @returns {{title: string, artist: string, album: string, year: string}}
 */
function parseId3v1(tail) {
  const empty = { title: '', artist: '', album: '', year: '' };
  if (tail.length < 128 || !matchText(tail, tail.length - 128, 'TAG')) {
    return empty;
  }
  // 'TAG' 占 3 字节，字段从它后面开始；ID3v1 没有编码位，中文通常是 GBK
  const start = tail.length - 128 + 3;
  const field = (offset, length) => cleanText(decodeLegacyText(tail.subarray(start + offset, start + offset + length)));
  return { title: field(0, 30), artist: field(30, 30), album: field(60, 30), year: field(90, 4) };
}

// ---------------------------------------------------------------------------
// Vorbis Comment（FLAC / OGG）
// ---------------------------------------------------------------------------

/**
 * 解析 Vorbis Comment 块。
 * @param {Uint8Array} bytes 块内容（从 vendor 长度开始）
 * @returns {{fields: Record<string, string>}}
 */
function parseVorbisComment(bytes) {
  const fields = {};
  let offset = 4; // 跳过 vendor 长度
  const vendorLength = readU32LE(bytes, 0);
  offset = 4 + vendorLength;
  if (offset + 4 > bytes.length) {
    return { fields };
  }
  const count = readU32LE(bytes, offset);
  offset += 4;
  for (let i = 0; i < count && offset + 4 <= bytes.length; i += 1) {
    const length = readU32LE(bytes, offset);
    offset += 4;
    if (length <= 0 || offset + length > bytes.length) {
      break;
    }
    const raw = bytes.subarray(offset, offset + length);
    offset += length;
    // '=' 只可能是 ASCII（GBK 尾字节最小 0x40），按字节切分再解值，
    // 这样 GBK 写的 Vorbis 注释（非标准但真实存在）也能救回来
    const eq = raw.indexOf(0x3d);
    if (eq <= 0) {
      continue;
    }
    const key = decodeText(raw.subarray(0, eq), 'iso-8859-1').toUpperCase();
    const value = cleanText(decodeLegacyText(raw.subarray(eq + 1)));
    if (value && !(key in fields)) {
      fields[key] = value;
    }
  }
  return { fields };
}

/**
 * 解析 FLAC PICTURE 块。
 * @param {Uint8Array} bytes 块内容
 * @returns {{blob: Blob, type: string, coverType: number}|null}
 */
function parseFlacPicture(bytes) {
  let offset = 4; // 图片类型（大端 4 字节，前 3 位是块头的 last-flag 已在调用处剥掉）
  const coverType = readU32BE(bytes, 0);
  const mimeLength = readU32BE(bytes, offset);
  offset += 4;
  const mime = cleanText(decodeText(bytes.subarray(offset, offset + mimeLength), 'iso-8859-1')).toLowerCase();
  offset += mimeLength;
  const descriptionLength = readU32BE(bytes, offset);
  offset += 4 + descriptionLength;
  // 宽 / 高 / 位深 / 调色板项
  offset += 16;
  const dataLength = readU32BE(bytes, offset);
  offset += 4;
  if (dataLength <= 0 || dataLength > MAX_IMAGE_BYTES || offset + dataLength > bytes.length) {
    return null;
  }
  const data = bytes.subarray(offset, offset + dataLength);
  const type = /^image\//.test(mime) ? mime : (sniffImageMime(data) ?? '');
  if (!type) {
    return null;
  }
  return { blob: new Blob([Uint8Array.prototype.slice.call(data)], { type }), type, coverType };
}

/**
 * 解析 FLAC：fLaC 魔数 + 元数据块链表。
 * @param {File} file 音频文件
 * @param {Uint8Array} head 已读到的头部字节
 * @returns {Promise<object>} 与 parseId3v2Frames 同构的结果
 */
async function parseFlac(file, head) {
  const result = { title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
  let offset = 4;
  let data = head;

  // 块可能超出已读范围（PICTURE 常见），需要时把窗口放大后重读
  const ensure = async (end) => {
    if (end <= data.length) {
      return;
    }
    data = await readSlice(file, 0, Math.min(MAX_TAG_BYTES, Math.max(end, data.length * 2)));
  };

  for (let guard = 0; guard < 64; guard += 1) {
    await ensure(offset + 4);
    if (offset + 4 > data.length) {
      break;
    }
    const blockHeader = data[offset];
    const last = (blockHeader & 0x80) !== 0;
    const type = blockHeader & 0x7f;
    const length = (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    if (length < 0 || offset + length > MAX_TAG_BYTES) {
      break;
    }
    await ensure(offset + length);

    const block = data.subarray(offset, offset + length);
    if (block.length === length) {
      if (type === 4) {
        const { fields } = parseVorbisComment(block);
        result.title ||= fields.TITLE ?? '';
        result.artist ||= fields.ARTIST ?? fields.ALBUMARTIST ?? '';
        result.albumArtist ||= fields.ALBUMARTIST ?? '';
        result.album ||= fields.ALBUM ?? '';
        result.year ||= (fields.DATE ?? fields.YEAR ?? '').match(/\d{4}/)?.[0] ?? '';
      } else if (type === 6 && !result.picture) {
        result.picture = parseFlacPicture(block);
      }
    }

    offset += length;
    if (last || (result.title && result.artist && result.picture)) {
      break;
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// MP4 / M4A（moov.udta.meta.ilst）
// ---------------------------------------------------------------------------

/** MP4 里常见的 iTunes 元数据 fourcc → 我们的字段名。 */
const MP4_TEXT_KEYS = {
  '©nam': 'title',
  '©ART': 'artist',
  aART: 'albumArtist',
  '©alb': 'album',
  '©day': 'year',
};

/**
 * 在给定字节窗口里找 moov 并解析 ilst。
 * @param {Uint8Array} view 窗口数据
 * @param {number} base 窗口在文件中的起始偏移（仅用于日志）
 * @returns {object|null} 找到 ilst 返回结果，否则 null
 */
function parseMp4Window(view, base) {
  void base;
  const moovOffset = findBox(view, 0, view.length, 'moov');
  if (moovOffset < 0) {
    return null;
  }
  const result = { title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
  const ilst = findIlst(view, moovOffset);
  if (!ilst) {
    return null; // 有 moov 没 ilst：这个窗口不是我们要找的（m4a 只有一个 moov，正常不会走到）
  }
  for (const item of ilst) {
    const key = MP4_TEXT_KEYS[item.name] ?? (item.name === 'covr' ? 'picture' : '');
    if (!key) {
      continue;
    }
    const dataBox = readDataAtom(view, item.valueStart, item.valueEnd);
    if (!dataBox) {
      continue;
    }
    if (key === 'picture') {
      if (dataBox.length > 0 && dataBox.length <= MAX_IMAGE_BYTES) {
        const type = sniffImageMime(dataBox) ?? 'image/jpeg';
        result.picture = { blob: new Blob([Uint8Array.prototype.slice.call(dataBox)], { type }), type, coverType: 3 };
      }
    } else {
      result[key] ||= cleanText(decodeText(dataBox, 'utf-8'));
    }
  }
  return result;
}

/**
 * 在 [from, to) 区间里按层级查找指定 fourcc 的 box。
 * @param {Uint8Array} view 数据
 * @param {number} from 起始
 * @param {number} to 结束
 * @param {string} name 目标 fourcc
 * @returns {number} box 起始偏移，找不到 -1
 */
function findBox(view, from, to, name) {
  let offset = from;
  while (offset + 8 <= to) {
    const size = readU32BE(view, offset);
    const type = decodeText(view.subarray(offset + 4, offset + 8), 'iso-8859-1');
    let header = 8;
    let body = size;
    if (size === 1) {
      // 64 位 largesize
      body = Number((BigInt(readU32BE(view, offset + 8)) << 32n) | BigInt(readU32BE(view, offset + 12)));
      header = 16;
    } else if (size === 0) {
      body = to - offset;
    }
    if (body < header || offset + body > to) {
      return -1; // 结构已损坏，别硬走
    }
    if (type === name) {
      return offset;
    }
    // 容器类型继续下钻
    if (/^(moov|udta|meta|ilst|trak|mdia|minf|stbl)$/.test(type)) {
      const inner = findBox(view, offset + header + (type === 'meta' ? 4 : 0), offset + body, name);
      if (inner >= 0) {
        return inner;
      }
    }
    offset += body;
  }
  return -1;
}

/**
 * 列出 ilst 下的所有条目。
 * @param {Uint8Array} view 数据
 * @param {number} moovOffset moov 起始
 * @returns {Array<{name: string, valueStart: number, valueEnd: number}>}
 */
function findIlst(view, moovOffset) {
  const meta = findBox(view, moovOffset + 8, view.length, 'meta');
  if (meta < 0) {
    return null;
  }
  const ilst = findBox(view, meta + 8 + 4, view.length, 'ilst');
  if (ilst < 0) {
    return null;
  }
  const items = [];
  let size = readU32BE(view, ilst);
  const ilstHeader = 8;
  if (size === 1) {
    // 64 位 largesize：本项目的文件不会用到，按「到窗口末尾」处理
    size = view.length - ilst;
  } else if (size === 0) {
    size = view.length - ilst;
  }
  const ilstEnd = Math.min(ilst + size, view.length);
  let offset = ilst + ilstHeader;
  while (offset + 8 <= ilstEnd && ilstEnd <= view.length) {
    const itemSize = readU32BE(view, offset);
    const name = decodeText(view.subarray(offset + 4, offset + 8), 'iso-8859-1');
    if (itemSize < 8 || offset + itemSize > view.length) {
      break;
    }
    items.push({ name, valueStart: offset + 8, valueEnd: offset + itemSize });
    offset += itemSize;
  }
  return items;
}

/**
 * 读条目里的 data 子 box（iTunes 的文本/图片都包在它里面）。
 * @param {Uint8Array} view 数据
 * @param {number} from 条目内容起点
 * @param {number} to 条目内容终点
 * @returns {Uint8Array|null}
 */
function readDataAtom(view, from, to) {
  let offset = from;
  while (offset + 8 <= to) {
    const size = readU32BE(view, offset);
    const type = decodeText(view.subarray(offset + 4, offset + 8), 'iso-8859-1');
    if (size < 8 || offset + size > to) {
      return null;
    }
    if (type === 'data') {
      return view.subarray(offset + 16, offset + size);
    }
    offset += size;
  }
  return null;
}

/**
 * 解析 M4A/MP4：moov 可能在文件头也可能在文件尾，两头各试一次。
 * @param {File} file 音频文件
 * @param {Uint8Array} head 头部字节
 * @returns {Promise<object>}
 */
async function parseMp4(file, head) {
  const attempts = [{ view: head, base: 0 }];
  if (findBox(head, 0, head.length, 'moov') < 0) {
    const tailSize = Math.min(MAX_TAG_BYTES, file.size);
    const tail = await readSlice(file, file.size - tailSize, tailSize);
    attempts.push({ view: tail, base: file.size - tailSize });
  }
  for (const attempt of attempts) {
    try {
      const parsed = parseMp4Window(attempt.view, attempt.base);
      if (parsed && (parsed.title || parsed.artist || parsed.picture)) {
        return parsed;
      }
    } catch (error) {
      console.error('[audio-tags] MP4 标签解析失败：', file.name, error);
    }
  }
  return { title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
}

// ---------------------------------------------------------------------------
// 对外入口
// ---------------------------------------------------------------------------

/**
 * 读取音频文件的内嵌标签与内嵌封面。
 * @param {File} file 用户导入的音频文件
 * @param {{maxBytes?: number}} [options] maxBytes 限制标签区读取量
 * @returns {Promise<{format: string, title: string, artist: string, album: string, albumArtist: string, year: string, picture: {blob: Blob, type: string, coverType: number}|null}>}
 *   任何一步失败都只影响对应字段，不会抛异常
 */
export async function readAudioTags(file, options = {}) {
  const empty = { format: 'unknown', title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
  if (!file || typeof file.slice !== 'function') {
    return empty;
  }
  const maxBytes = Math.min(options.maxBytes ?? MAX_TAG_BYTES, MAX_TAG_BYTES);
  try {
    let head = await readSlice(file, 0, Math.min(PROBE_BYTES, maxBytes));
    if (head.length === 0) {
      return empty;
    }

    // ID3v2：'ID3' 打头（MP3 最常见，AIFF/部分 WAV 也这么放）
    if (matchAt(head, 0, [0x49, 0x44, 0x33])) {
      const version = head[3];
      const flags = head[5];
      const tagSize = readSynchsafe(head, 6);
      const result = { ...empty, format: 'mp3' };
      if (tagSize > 0 && version >= 2 && version <= 4) {
        const tagBytes = await readSlice(file, 10, Math.min(tagSize, maxBytes));
        const parsed = parseId3v2Frames(tagBytes, version, flags);
        Object.assign(result, parsed);
      }
      // v2 没给全（有些文件只有 v1），补读文件末尾 128 字节
      if (!result.title || !result.artist) {
        const tail = await readSlice(file, Math.max(0, file.size - 128), 128);
        const v1 = parseId3v1(tail);
        result.title ||= v1.title;
        result.artist ||= v1.artist;
        result.album ||= v1.album;
        result.year ||= v1.year;
      }
      return result;
    }

    if (matchText(head, 0, 'fLaC')) {
      const parsed = await parseFlac(file, head);
      return { ...empty, format: 'flac', ...parsed };
    }

    if (matchText(head, 0, 'OggS')) {
      const parsed = await parseOgg(file, head);
      return { ...empty, format: 'ogg', ...parsed };
    }

    if (matchText(head, 4, 'ftyp')) {
      const parsed = await parseMp4(file, head);
      return { ...empty, format: 'm4a', ...parsed };
    }

    // 裸 MPEG / ADTS 帧（没有 ID3v2 打头）：尾部仍可能挂着 ID3v1
    if (head[0] === 0xff && (head[1] & 0xe0) === 0xe0) {
      const tail = await readSlice(file, Math.max(0, file.size - 128), 128);
      const v1 = parseId3v1(tail);
      return { ...empty, format: 'mp3', ...v1 };
    }
  } catch (error) {
    console.error('[audio-tags] 读取标签失败：', file?.name, error);
  }
  return empty;
}

/**
 * 解析 OGG：把前几页的 body 拼起来找 Vorbis comment 报文。
 * @param {File} file 音频文件
 * @param {Uint8Array} head 头部字节
 * @returns {Promise<object>}
 */
async function parseOgg(file, head) {
  const result = { title: '', artist: '', album: '', albumArtist: '', year: '', picture: null };
  let data = head;
  // 拼接前几页的负载，直到能看见 comment 报文（Vorbis 的第 2 个报文，以 0x03 'vorbis' 开头）
  let start = 0;
  for (let guard = 0; guard < 8; guard += 1) {
    start = data.indexOf(0x03, start);
    if (start < 0) {
      break;
    }
    if (matchText(data, start + 1, 'vorbis')) {
      break;
    }
    start += 1;
  }
  if (start < 0) {
    return result;
  }
  const commentStart = start + 7; // 0x03 + 'vorbis'
  const vendorLength = readU32LE(data, commentStart);
  let needed = commentStart + 4 + vendorLength + 4;
  if (needed > data.length) {
    data = await readSlice(file, 0, Math.min(MAX_TAG_BYTES, Math.max(data.length * 2, needed)));
  }
  const commentBody = data.subarray(commentStart);
  const { fields } = parseVorbisComment(commentBody);
  result.title = fields.TITLE ?? '';
  result.artist = fields.ARTIST ?? fields.ALBUMARTIST ?? '';
  result.albumArtist = fields.ALBUMARTIST ?? '';
  result.album = fields.ALBUM ?? '';
  result.year = (fields.DATE ?? fields.YEAR ?? '').match(/\d{4}/)?.[0] ?? '';

  // 封面：METADATA_BLOCK_PICTURE 是 base64 的 FLAC PICTURE 块
  if (fields.METADATA_BLOCK_PICTURE) {
    try {
      const binary = atob(fields.METADATA_BLOCK_PICTURE.replace(/\s/g, ''));
      const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
      result.picture = parseFlacPicture(bytes);
    } catch (error) {
      console.error('[audio-tags] OGG 内嵌封面解码失败：', error);
    }
  }
  return result;
}

/**
 * 把标签里的歌手/曲名归一成展示字段（标签优先，缺什么补什么）。
 * @param {{title?: string, artist?: string, album?: string, albumArtist?: string}} tags readAudioTags 的结果
 * @param {{title: string, artist: string}} fromName 文件名解析出来的结果
 * @returns {{title: string, artist: string, usedTags: boolean}}
 */
export function mergeTaggedNames(tags, fromName) {
  const title = cleanText(tags?.title) || fromName.title;
  const artist = cleanText(tags?.artist) || cleanText(tags?.albumArtist) || fromName.artist;
  const usedTags = Boolean(cleanText(tags?.title) || cleanText(tags?.artist) || cleanText(tags?.albumArtist));
  return { title, artist, usedTags };
}
