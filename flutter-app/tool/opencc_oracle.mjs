// 用法：node tool/opencc_oracle.mjs   （在 flutter-app/ 下跑）
// 用 opencc-js 本体产出「输入 → 期望输出」对，Dart 侧逐条比对。
// 只测 tw2s 本体，不含 妳/甚么 后处理（那两条另有独立用例）。
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, '..');
// 与 src/lib/chinese.ts 完全相同的入口：`opencc-js/t2cn` 的 ESM 产物，
// 它直接导出已绑定 preset 的 Converter。
// 已用 node 实测导出名：Converter / ConverterFactory / CustomConverter /
// HTMLConverter / Locale / Trie / default，取 Converter。
const { Converter } = await import(pathToFileURL(
  path.resolve(appRoot, '../node_modules/opencc-js/dist/esm/t2cn.js'),
).href);
const convert = Converter({ from: 'tw', to: 'cn' });

const inputs = [
  '', '十年', '陳奕迅', '你好，世界',
  '幹麵好吃', '頭髮很長', '裡面有鐘錶', '皇后與後宮',
  '計算機程式', '資料庫', '網路連線', '滑鼠與鍵盤',
  '臺灣', '台北', '高雄', '記憶體', '硬碟', '螢幕',
  '為什麼', '甚麼', '妳好', '甚么',
  '﨑', '⿰甲乙', '𠀀', '混合 English 與中文',
  '[00:01.00]繁體歌詞第一句\n[00:05.00]第二句在這裡',
  '髮型設計師', '麵條', '乾脆', '幹部', ' later ',
];
const pairs = inputs.map((input) => ({ input, expected: convert(input) }));
mkdirSync(path.join(appRoot, 'test/fixtures'), { recursive: true });
writeFileSync(
  path.join(appRoot, 'test/fixtures/opencc_golden.json'),
  JSON.stringify(pairs, null, 2) + '\n',
  'utf8',
);
console.log('generated opencc_golden.json, pairs=' + pairs.length);