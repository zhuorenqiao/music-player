/**
 * demo-data.js —— 内置示例曲目
 *
 * 音频由 tools/gen_demo_audio.py 生成（44100Hz / 16bit / 单声道 WAV），
 * 封面为 assets/covers 下的 SVG。duration 为生成脚本输出的实际时长，
 * 播放时还会被 audio 元素的真实元数据再覆盖一次。
 *
 * lyrics 为标准 LRC 文本（可带 [ti:] / [ar:] / [offset:] 标签），
 * 时间轴与上面的 duration 对齐，由 lyrics.js 解析。
 */

/** 本地文件没有封面资源时使用的兜底封面。 */
export const DEFAULT_COVER = 'assets/covers/cover-default.svg';

/** 内置示例曲目（3 首，风格不同）。 */
export const DEMO_TRACKS = Object.freeze([
  {
    id: 'demo-morning-dawn',
    title: '晨光序曲',
    artist: 'Aurora Lab',
    album: 'Neon Dawn',
    cover: 'assets/covers/cover-01.svg',
    src: 'assets/audio/track-01.wav',
    duration: 21.32,
    isLocal: false,
    lyrics: `[ti:晨光序曲]
[ar:Aurora Lab]
[al:Neon Dawn]
[00:00.00]（前奏）
[00:02.50]天还没亮 窗棂先醒了
[00:05.20]一线微光 落在旧唱片上
[00:08.00]我把夜色 折成纸船
[00:10.80]放进你留下的 那杯温茶
[00:13.40]风穿过走廊 带走了困意
[00:16.00]城市翻身 继续做梦
[00:18.20]而我只想 记住这一刻
[00:20.10]晨光把一切 重新命名`,
  },
  {
    id: 'demo-neon-night',
    title: '霓虹夜行',
    artist: 'Aurora Lab',
    album: 'Midnight Drive',
    cover: 'assets/covers/cover-02.svg',
    src: 'assets/audio/track-02.wav',
    duration: 23.68,
    isLocal: false,
    lyrics: `[ti:霓虹夜行]
[ar:Aurora Lab]
[al:Midnight Drive]
[00:00.00]（前奏）
[00:02.80]霓虹把影子 拉得很长
[00:05.60]红绿灯之间 我们都在等
[00:08.40]车窗倒影里 是另一个我
[00:11.20]沿着环线 一直往南开
[00:14.00]雨没落下 却已经潮湿
[00:16.80]电台里唱着 谁的心事
[00:19.40]别问终点 有没有灯
[00:21.90]夜还很长 我们很轻`,
  },
  {
    id: 'demo-seaside-books',
    title: '海边书店',
    artist: 'Aurora Lab',
    album: 'Slow Afternoon',
    cover: 'assets/covers/cover-03.svg',
    src: 'assets/audio/track-03.wav',
    duration: 25.07,
    isLocal: false,
    lyrics: `[ti:海边书店]
[ar:Aurora Lab]
[al:Slow Afternoon]
[00:00.00]（前奏）
[00:03.00]海风翻到 第三十七页
[00:06.00]有人在读 一封没寄出的信
[00:09.00]木地板响 像退潮的声音
[00:12.00]咖啡凉了 也没人催促
[00:15.00]我把书签 放回原来的行
[00:18.00]像把一个夏天 悄悄归位
[00:21.00]潮水涨落 都是借口
[00:23.60]留下的人 才需要理由`,
  },
]);

/**
 * 取一份可安全修改的示例列表副本（深拷贝一层）。
 * @returns {object[]} 曲目数组
 */
export function createDemoTracks() {
  return DEMO_TRACKS.map((track) => ({ ...track }));
}
