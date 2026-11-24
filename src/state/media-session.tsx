import type { ReactNode } from 'react';
import { useEffect, useRef } from 'react';
import { coverForDisplay } from './covers';
import { usePlayer } from './player';
import { useRadio } from './radio';
import type { RadioStation } from '../lib/radio';

/**
 * 系统媒体卡片（Windows 媒体浮层 / Chrome 媒体中心 / 手机浏览器通知）的桥。
 *
 * 和 Flutter 端 `MediaSessionCoordinator` 同一套规则：
 *   * App 只有一张卡片，音乐与电台「谁在响谁接管」；
 *   * 电台是直播：只给播放 / 暂停 / 关闭，不给上一台 / 下一台 / 进度；
 *   * 都没响时，卡片留在最后响过的那条链路（用户刚暂停的电台不会被
 *     同样暂停的音乐顶掉）。
 *
 * 浏览器只认 `navigator.mediaSession`，没有原生通知栏那种「应用名 + 大封面」，
 * 但元数据、可用按钮和进度都由这里决定，Windows 的媒体浮层会照着画。
 */

const RADIO_GREEN_DARK = '#062c22';
const RADIO_GREEN_MID = '#6fe9c0';
const RADIO_GREEN_LIGHT = '#d7f9ec';

/** 电台封面：画一张和 App 内电台大卡同族的浅绿方形图，按台缓存。 */
const radioArtworkCache = new Map<string, string>();

function radioArtworkUrl(station: RadioStation): string {
  const cached = radioArtworkCache.get(station.id);
  if (cached) return cached;

  const size = 512;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (!ctx) return '';

  // 浅绿渐变：左上更白，右下落到品牌绿，和电台卡的 cardTint 一个走向。
  const bg = ctx.createLinearGradient(0, 0, size, size);
  bg.addColorStop(0, RADIO_GREEN_LIGHT);
  bg.addColorStop(0.55, RADIO_GREEN_MID);
  bg.addColorStop(1, '#2ee6a8');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, size, size);

  // 右上三圈同心环（界面大卡的同款装饰，换到方形画布里居中偏右上）。
  ctx.strokeStyle = 'rgba(6, 44, 34, 0.10)';
  for (let i = 1; i <= 3; i += 1) {
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(size * 0.78, size * 0.24, size * (0.10 + i * 0.075), 0, Math.PI * 2);
    ctx.stroke();
  }

  // 首字：系统卡片旁边已经很挤，图里只留一个能认出是哪一台的字。
  const initial = Array.from(station.name.trim())[0] ?? '台';
  ctx.fillStyle = RADIO_GREEN_DARK;
  ctx.font = '700 210px "PingFang SC","Microsoft YaHei","Noto Sans SC",sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(initial, size * 0.5, size * 0.47);

  // 底部四根波形条，与列表缩略图同一套语汇。
  const barWidth = size * 0.035;
  const barGap = size * 0.045;
  const heights = [0.07, 0.12, 0.09, 0.05];
  const startX = size * 0.5 - (heights.length * barWidth + (heights.length - 1) * barGap) / 2;
  ctx.fillStyle = 'rgba(6, 44, 34, 0.35)';
  heights.forEach((h, i) => {
    const x = startX + i * (barWidth + barGap);
    ctx.beginPath();
    ctx.roundRect(x, size * 0.72, barWidth, size * h, barWidth / 2);
    ctx.fill();
  });

  ctx.fillStyle = 'rgba(6, 44, 34, 0.55)';
  ctx.font = '600 24px "PingFang SC","Microsoft YaHei","Noto Sans SC",sans-serif';
  ctx.fillText('L I V E   R A D I O', size * 0.5, size * 0.86);

  const url = canvas.toDataURL('image/png');
  radioArtworkCache.set(station.id, url);
  return url;
}

function supportsMediaSession(): boolean {
  return (
    typeof navigator !== 'undefined' &&
    'mediaSession' in navigator &&
    typeof MediaMetadata !== 'undefined'
  );
}

export function MediaSessionProvider({ children }: { children: ReactNode }) {
  const player = usePlayer();
  const radio = useRadio();
  const lastSource = useRef<'music' | 'radio'>('music');

  const musicPlaying = player.playing;
  const radioPlaying = radio.current !== null && radio.playing;

  useEffect(() => {
    if (musicPlaying) lastSource.current = 'music';
  }, [musicPlaying]);

  useEffect(() => {
    if (radioPlaying) lastSource.current = 'radio';
  }, [radioPlaying]);

  // 选台 / 重连这一拍还没有声音，但用户意图明确是电台：卡片先让给它。
  useEffect(() => {
    if (radio.current && (radio.loading || radio.reconnecting)) {
      lastSource.current = 'radio';
    }
  }, [radio.current, radio.loading, radio.reconnecting]);

  const source: 'music' | 'radio' | null = radioPlaying
    ? 'radio'
    : musicPlaying
      ? 'music'
      : radio.current && (radio.loading || radio.reconnecting)
        ? 'radio'
        : radio.current && lastSource.current === 'radio'
          ? 'radio'
          : player.current
            ? 'music'
            : radio.current
              ? 'radio'
              : null;

  // 元数据：标题 / 副标题 / 封面 / 播放态。电台没有时长，不设进度。
  useEffect(() => {
    if (!supportsMediaSession()) return;
    const session = navigator.mediaSession;

    if (source === 'radio' && radio.current) {
      const station = radio.current;
      session.metadata = new MediaMetadata({
        title: station.name,
        // 与 Flutter 端逐字一致：分类行 + 直播；系统没有独立 LIVE 徽标。
        artist: `${station.city} · 直播`,
        album: '流光音乐 · 电台',
        artwork: [
          {
            src: radioArtworkUrl(station),
            sizes: '512x512',
            type: 'image/png',
          },
        ],
      });
      session.playbackState = radio.playing ? 'playing' : 'paused';
      // 直播没有进度：必须清掉上一首歌留下的 position state。
      // Chrome / Edge 的系统卡片会记住最后一次 setPositionState，
      // 不清的话电台卡片上会一直挂着「00:33 / 05:34」那条进度。
      // 传空对象是规范里的「清除」语义（不是省略参数那么含糊）。
      try {
        session.setPositionState();
      } catch {
        // 个别浏览器实现不接受空参；进度条最多残留，不影响播放。
      }
      return;
    }

    if (source === 'music' && player.current) {
      const track = player.current;
      const cover = coverForDisplay(track);
      session.metadata = new MediaMetadata({
        title: track.title,
        artist: track.artist,
        album: track.album ?? '',
        artwork: cover
          ? [
              {
                src: cover,
                sizes: '512x512',
                type: cover.startsWith('data:image/svg') ? 'image/svg+xml' : 'image/png',
              },
            ]
          : [],
      });
      session.playbackState = player.playing ? 'playing' : 'paused';
      return;
    }

    session.metadata = null;
    session.playbackState = 'none';
    try {
      session.setPositionState();
    } catch {
      // 同上：空状态本来就不该有进度。
    }
  }, [
    source,
    radio.current,
    radio.playing,
    player.current,
    player.playing,
  ]);

  // 音乐进度：每秒一次，位置超过总长就不再写（系统会 DUMP 参数错误）。
  // 电台 / 空态不但不写，还要主动清除：系统卡片会记住最后一次位置，
  // 上一首歌的「00:33 / 05:34」会原样挂在电台卡片上。
  useEffect(() => {
    if (!supportsMediaSession()) return;
    const session = navigator.mediaSession;
    if (source !== 'music') {
      try {
        session.setPositionState();
      } catch {
        // 清除失败最多是残留一条进度，不影响播放与按钮。
      }
      return;
    }
    const engine = player.player;
    let lastAt = 0;
    const sync = () => {
      const now = Date.now();
      if (now - lastAt < 900) return;
      lastAt = now;
      const duration = engine.duration;
      const position = engine.currentTime;
      if (!Number.isFinite(duration) || duration <= 0) return;
      if (!Number.isFinite(position) || position < 0 || position > duration) return;
      try {
        session.setPositionState({
          duration,
          playbackRate: 1,
          position,
        });
      } catch {
        // 位置/时长越界时浏览器会抛；进度条不画就是了，不影响播放。
      }
    };
    sync();
    const off = engine.on('timeupdate', sync);
    return () => {
      off();
      try {
        session.setPositionState();
      } catch {
        // 切歌 / 切电台时先把旧时长清掉，新的位置由下一拍补上。
      }
    };
  }, [source, player.current, player.player]);

  // 按钮：按当前接管方注册。电台只给 play / pause / stop，其余全部摘掉。
  useEffect(() => {
    if (!supportsMediaSession()) return;
    const session = navigator.mediaSession;

    const handlers: Array<[MediaSessionAction, MediaSessionActionHandler | null]> = [];
    const set = (action: MediaSessionAction, handler: MediaSessionActionHandler | null) => {
      handlers.push([action, handler]);
      try {
        session.setActionHandler(action, handler);
      } catch {
        // 某些浏览器不支持某个动作（例如 stop），忽略即可。
      }
    };

    if (source === 'radio' && radio.current) {
      set('play', () => {
        if (!radio.playing) radio.toggle();
      });
      set('pause', () => radio.pause());
      set('stop', () => radio.stop());
      set('previoustrack', null);
      set('nexttrack', null);
      set('seekto', null);
      set('seekbackward', null);
      set('seekforward', null);
    } else if (source === 'music' && player.current) {
      set('play', () => {
        if (!player.playing) player.togglePlay();
      });
      set('pause', () => player.pause());
      set('previoustrack', () => player.playPrevTrack());
      set('nexttrack', () => player.playNext());
      set('seekto', (details) => {
        if (details.seekTime != null) player.seek(details.seekTime);
      });
      set('seekbackward', () => player.seek(player.player.currentTime - 15));
      set('seekforward', () => player.seek(player.player.currentTime + 15));
      set('stop', null);
    }

    return () => {
      handlers.forEach(([action]) => {
        try {
          session.setActionHandler(action, null);
        } catch {
          // 同上：不支持的动作本来就注册不上，摘的时候也不用管。
        }
      });
    };
  }, [
    source,
    radio.current,
    radio.playing,
    radio.pause,
    radio.toggle,
    radio.stop,
    player.current,
    player.playing,
    player.togglePlay,
    player.pause,
    player.playNext,
    player.playPrevTrack,
    player.seek,
    player.player,
  ]);

  return children;
}
