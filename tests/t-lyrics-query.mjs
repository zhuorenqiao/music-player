/**
 * t-lyrics-query.mjs —— 曲名清洗：伴奏类尾部标签
 *
 * 只测 normalizeQuery（纯函数）；客户端网络编排在 t-lyrics.mjs / t-lyrics-remote.mjs。
 */

const root = new URL('../', import.meta.url);
const bundleUrl = new URL('.cache/test/lyrics-source.bundle.mjs', root);
const { normalizeQuery } = await import(bundleUrl.href);

let failed = 0;
const check = (label, condition, extra = '') => {
  if (condition) {
    console.log(`ok  ${label}`);
  } else {
    console.error(`FAIL ${label}${extra ? ` ${extra}` : ''}`);
    failed += 1;
  }
};

const airport = normalizeQuery({
  title: '飞机场的10:30伴奏',
  artist: '陶喆',
  duration: 301,
});
check('直接拼接「伴奏」→ 还原正式曲名', airport.trackName === '飞机场的10:30', JSON.stringify(airport));
check('歌手保持陶喆', airport.artistName === '陶喆', JSON.stringify(airport));

const catherine = normalizeQuery({
  title: 'Catherine - 伴奏',
  artist: '陶喆',
  duration: 233,
});
check('「 - 伴奏」→ Catherine', catherine.trackName === 'Catherine', JSON.stringify(catherine));

const stacked = normalizeQuery({
  title: 'Catherine 伴奏 完整版',
  artist: '陶喆',
  duration: 233,
});
check('叠加标签「伴奏 完整版」也能剥干净', stacked.trackName === 'Catherine', JSON.stringify(stacked));

const pureAccompaniment = normalizeQuery({
  title: 'Catherine 纯伴奏',
  artist: '陶喆',
  duration: 233,
});
check('「纯伴奏」整段剥掉，不留下「纯」', pureAccompaniment.trackName === 'Catherine', JSON.stringify(pureAccompaniment));

const localAirport = normalizeQuery({
  title: '陶喆 - 飞机场的10:30伴奏',
  artist: '本地文件',
  duration: 0,
});
check('本地文件名带伴奏：反推出正确曲名', localAirport.trackName === '飞机场的10:30', JSON.stringify(localAirport));
check('本地文件名带伴奏：反推出正确歌手', localAirport.artistName === '陶喆', JSON.stringify(localAirport));

const localCatherine = normalizeQuery({
  title: '陶喆 - Catherine - 伴奏',
  artist: '本地文件',
  duration: 0,
});
check('本地文件名「歌手 - 曲名 - 伴奏」：曲名是 Catherine', localCatherine.trackName === 'Catherine', JSON.stringify(localCatherine));
check('本地文件名「歌手 - 曲名 - 伴奏」：歌手是陶喆', localCatherine.artistName === '陶喆', JSON.stringify(localCatherine));

const bare = normalizeQuery({ title: '伴奏', artist: '某某', duration: 0 });
check('曲名本身就是「伴奏」时不被剥空', bare.trackName === '伴奏', JSON.stringify(bare));

const live = normalizeQuery({ title: 'Live Forever', artist: 'Oasis', duration: 0 });
check('英文 Live 不裸剥，避免误伤真歌名', live.trackName === 'Live Forever', JSON.stringify(live));

if (failed > 0) {
  console.error(`\n${failed} 条失败`);
  process.exit(1);
}
console.log('\n全部通过');
