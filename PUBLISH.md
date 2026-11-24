# 发布线上版本（doubao-html 网页应用）

- 线上地址：https://xcnmgeke1pja.doubao.link/app/app_17j7001a83g
- 应用 ID：`app_17j7001a83g`（类型 `modern_html`，应用名取自产物目录，暂叫 publish）
- 产物目录：`publish/`（静态站点，不进 git 也无所谓，重新构建即可覆盖）

## 重新发布

```powershell
# 1. 构建成可放在任意子路径下的静态包：base 用相对路径，产物写到 publish/
npx vite build --base=./ --outDir publish --emptyOutDir

# 2. 去掉发布用不着的 sourcemap（省 1MB）
Remove-Item -LiteralPath publish\assets\*.js.map

# 3. 整目录发布，沿用同一个应用
Set-Location -LiteralPath publish
lark-cli apps +deploy --dir . --app-id app_17j7001a83g

# 4. 轮询到 finished 才算上线，拿 online_url
lark-cli apps +release-get --app-id app_17j7001a83g --release-id <上一步返回的 release_id>
```

## 两个坑（都是踩过的）

**1. 必须用 `--dir`，不要用 `--file-path`。**
`--file-path` 只跟随页面里静态写死的引用（`<link>` / `<script src>` / `<img src>` / CSS `url()`），
而部分静态资源路径是 JS 运行时拼的（例如兜底封面 `assets/covers/cover-default.svg` 由 `src/lib/demo-data.js` 导出、由状态层拼给 `<img>`），内置字体样式表也是运行时挂进 `<head>`。
用 `--file-path` 发布实测漏过这类资源（线上 404，封面裂图、歌词字体不生效）；早先的 3 首 demo 音频正是这样漏掉的，那批示例曲目现已整体移除。
`--dir` 原样打包整个目录，才齐全 —— 已用 `+export` 拉回发布包核对过（120 项，封面字体都在）。

**2. 字体路径必须是相对当前页面的。**
`src/lib/lyric-fonts.ts` 里两个 `webFont` 从 `'/fonts/...'` 改成了 `'fonts/...'`：
dev 在根路径下解析结果不变；线上应用挂在 `/app/<id>/` 子路径，绝对路径会 404。
以后加内置字体样式表也照这个写法。

## 发布前本地自检（可选）

```powershell
Set-Location -LiteralPath publish
python -m http.server 5123 --bind 127.0.0.1
# 浏览器打开 http://localhost:5123/ ：封面、播放、歌词字体是否正常
```

## 线上歌词中转（汽水 / 酷狗）

线上静态站不能直连汽水、酷狗（两家都没有 CORS 头），`src/lib/lyrics-source.js` 在
production 构建里会自动把 `api/lyrics` 换成 CloudBase 中转：

```
https://caidan-1-d9glqugbu5be15778-1316655607.ap-shanghai.app.tcloudbase.com/api/lyrics
```

- CloudBase 环境：`caidan-1-d9glqugbu5be15778`，函数 `lyrics-relay-v2`，网关路由 `/api`；
- 网关路由必须 `enableSafeDomain=false`（关掉网关自己的跨域校验），由函数返回
  `Access-Control-Allow-Origin: *`；两边同时写会变成 `origin,*`，浏览器会判为非法多值；
- 线上四源顺序是 `LRCLIB → 汽水 → 酷狗 → 网易云`：LRCLIB 有 CORS，由浏览器先直连；
  中转只查汽水、酷狗，没词时返回 `{status:'not-found', fallback:true}`，客户端继续直连网易云；
- 本地开发仍走 Vite 的 `api/lyrics`；需要临时改地址可设 `window.__LIGHT_MUSIC_LYRICS_PROXY__`。

## 注意

- 发布是异步的，`+release-get` 看到 `status=finished` 并且有 `online_url` 才算上线。
- 判断成败看返回 JSON 的 `ok`，不要看退出码。
- 发布后不要再拿 curl / 浏览器去访问 `online_url` 判断可用性：检查环境可能没有登录态，打开的是登录页。
- `publish/` 里别留 zip / 临时文件：`--dir` 会把目录里所有东西都打进包。
