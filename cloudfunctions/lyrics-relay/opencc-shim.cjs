/**
 * 中转函数专用的 OpenCC 空实现。
 *
 * opencc-js 的 t2cn 词典接近 200KB，而中转只负责「查词」——认歌用的标题/歌手
 * 基本都是简体，没必要把整本词典塞进云函数。这里保留 Converter 接口，
 * 原样返回文本；主站和 Flutter 端仍然用完整的 OpenCC。
 */
function Converter() {
  return (text) => String(text ?? '');
}

module.exports = { Converter };
