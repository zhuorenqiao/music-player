// 用法：node tool/gen_opencc_dicts.mjs   （在 flutter-app/ 下跑）
// 从 React 侧已装好的 opencc-js 取 tw2s 用到的五份词典，生成 Dart 源码。
// 不联网、不装包；词典缺失时直接报错退出。
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, '..');
const dictDir = path.resolve(appRoot, '../node_modules/opencc-js/dist/esm-lib/dict');

const entries = [
  ['kDictCjkCompatibility', 'CJK_Compatibility_Ideographs'],
  ['kDictTwVariantsRevPhrases', 'TWVariantsRevPhrases'],
  ['kDictTwVariantsRev', 'TWVariantsRev'],
  ['kDictTsPhrases', 'TSPhrases'],
  ['kDictTsCharacters', 'TSCharacters'],
];

const unsafe = new Set(["'", '\\', '$', '\n', '\r', '\t']);
const out = [
  '// lib/lyrics/opencc/dicts.dart',
  '// 生成物：由 tool/gen_opencc_dicts.mjs 从 opencc-js 的词典生成，不要手改。',
  '// 数据来源：opencc-js (MIT) 及其上游 OpenCC 词典 (Apache-2.0)，',
  '// 许可全文见 third_party/opencc-js-LICENSE.txt 与 third_party/opencc-LICENSE.txt。',
  '',
];
let total = 0;
for (const [name, file] of entries) {
  const mod = await import(pathToFileURL(path.join(dictDir, file + '.js')).href);
  const text = mod.default;
  if (typeof text !== 'string' || text.length === 0) throw new Error('bad dict: ' + file);
  for (const ch of text) {
    if (unsafe.has(ch)) throw new Error('unsafe char in ' + file + ': ' + JSON.stringify(ch));
  }
  for (const line of text.split('|')) {
    if (line.split(' ').length !== 2) throw new Error('bad entry in ' + file + ': ' + line);
  }
  total += text.split('|').length;
  out.push('const String ' + name + " = r'" + text + "';", '');
}
out.push('/// 五份词典的条目总数，供用例断言生成物完整（当前 6157）。');
out.push('const int kOpenccDictEntryCount = ' + total + ';');
mkdirSync(path.join(appRoot, 'lib/lyrics/opencc'), { recursive: true });
writeFileSync(path.join(appRoot, 'lib/lyrics/opencc/dicts.dart'), out.join('\n') + '\n', 'utf8');
console.log('generated dicts.dart, entries=' + total);