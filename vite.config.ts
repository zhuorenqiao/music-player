import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { musicApi } from './src/server/music-api';

/**
 * 开发期就带上三个同源代理（/api/lyrics、/api/cover、/api/artist-image），
 * 所以 `npm run dev` 一个进程即可，不再需要旁边的 serve.py。
 *
 * 注意：中间件只存在于 dev server。`npm run build` 出来的是纯静态站点，
 * 前端会自动降级（歌词/封面走浏览器直连，歌手写真图走维基 CORS）——
 * 与 vanilla 版「没有本地服务时」的行为一致。
 */
export default defineConfig({
  plugins: [react(), musicApi()],
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: false,
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
});
