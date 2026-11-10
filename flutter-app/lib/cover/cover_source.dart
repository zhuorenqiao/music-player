// lib/cover/cover_source.dart
//
// 取图字节接缝与生产实现（matchCover / matchArtistImage 编排是 Task 5 的活，
// 本文件先立接缝）。对译 React 服务端 music-api.ts:705-718 的封面图片下载：
// Flutter 侧直连 iTunes 的 artworkUrl600，不经过 api/cover 代理（M2a 同款
// 裁定）。字节下载与 JSON 查询分开两条接缝：响应是二进制、上限逻辑不同
//（8MB 防内存打爆），共用 HttpJsonClient 的 outcome 风格但状态集不一样。
// 纯 Dart + package:http，无 Flutter 依赖；IO 经 ImageBytesClient 接缝注入，
// 测试不碰真网络。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见
// test/cover/cover_disk_cache_test.dart / test/cover/cover_source_test.dart）：
// * 8MB 上限用**流式 send + 双刀**：第一刀读 `streamed.contentLength`（真实
//   IO 客户端下即 wire 头的 Content-Length）超限就不读体；第二刀按累计字节
//   兜底（头缺失时）。注意不能用 client.get —— 非流式的
//   `Response.contentLength` 会被 bodyBytes.length 覆盖，第一刀就瞎了；
//   MockClient.streaming 正好能透传声明值，两条刀都有用例钉。
// * 非 200 是「状态」，不是网络错：404 是「条目不存在」，调用方按未命中处理。
// * 超时 / 网络异常 / 解不出 URL 都归 network；不重试、不进冷却闸
//  （Global Constraints：封面链路失败静默下沉）。
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../lyrics/query.dart' show LyricsQuery, normalizeQuery;
import '../lyrics/upstream.dart'
    show HttpJsonClient, RequestAborted;
import 'cover_disk_cache.dart';
import 'itunes_source.dart' show CoverMatch, itunesSearch;

/// 下载字节上限（task 3 指令）：Content-Length 超限或累计超限都当失败。
const int kCoverDownloadLimitBytes = 8 * 1024 * 1024;

/// 单程超时：对齐 React 服务端 IMAGE_TIMEOUT（music-api.ts IMAGE_TIMEOUT = 15s）。
const Duration kCoverDownloadTimeout = Duration(seconds: 15);

/// 二进制 GET 接缝：下载封面图字节。测试注入假实现，绝不打网络。
abstract class ImageBytesClient {
  Future<ImageBytesOutcome> getBytes(Uri url, {required Duration timeout});
}

/// 一次 getBytes 的结果：成功 / 超时 / 网络 / 状态码四态
///（风格对齐 lyrics/upstream.dart 的 JsonOutcome）。
sealed class ImageBytesOutcome {
  const ImageBytesOutcome();
}

class ImageBytesOk extends ImageBytesOutcome {
  const ImageBytesOk(this.bytes);
  final Uint8List bytes;
}

class ImageBytesTimeout extends ImageBytesOutcome {
  const ImageBytesTimeout();
}

class ImageBytesNetwork extends ImageBytesOutcome {
  const ImageBytesNetwork();
}

class ImageBytesStatus extends ImageBytesOutcome {
  const ImageBytesStatus(this.status);
  final int status;
}

/// 生产实现：package:http 直连，懒建内核（注释理由照抄 HttpJsonClientImpl ——
/// 构造即开 HttpClient 会触发 testWidgets 警告），单程 timeout；8MB 上限见
/// 文件头「非显而易见语义」节。
class ImageBytesClientImpl implements ImageBytesClient {
  // 懒建理由逐字沿用 lyrics/upstream.dart HttpJsonClientImpl 的注释：
  // `http.Client()` 在构造时就会开一个真 HttpClient。组合根装配在
  // `buildBootstrap` 里建它，而 testWidgets 跑在 TestWidgetsFlutterBinding 下：
  // 哪怕一整个测试都注入了假 bytes client、根本不会发请求，光是构造就会触发
  // 「provide your own HttpClient implementation」警告，并让框架把所有请求
  // 统一回 400。所以把真实内核**懒建到第一次 getBytes**：生产行为不变
  //（第一次请求照样开），启动装配与测试则一个 socket 都不碰。
  ImageBytesClientImpl({http.Client? inner}) : _explicitInner = inner;

  final http.Client? _explicitInner;
  http.Client? _lazyInner;

  http.Client get _inner => _explicitInner ?? (_lazyInner ??= http.Client());

  @override
  Future<ImageBytesOutcome> getBytes(
    Uri url, {
    required Duration timeout,
  }) async {
    try {
      // 流式 send 而不是 client.get：**只有流式响应才把 wire 头里的
      // Content-Length 透出到 `streamed.contentLength`**（非流式的
      // `Response.contentLength` 会被 bodyBytes.length 覆盖，8MB 第一刀
      // 就读不到真实声明值 —— MockClient.streaming 测的就是这条路）。
      final streamed = await _inner
          .send(http.Request('GET', url)..headers['Accept'] = 'image/*')
          .timeout(timeout);
      final status = streamed.statusCode;
      if (status < 200 || status >= 300) {
        await streamed.stream.drain<void>();
        return ImageBytesStatus(status);
      }
      // 8MB 上限第一刀：Content-Length 响应头超限 → 不读体直接失败
      // （防内存打爆；gzip 传输时它是压缩大小，仍能挡住绝大多数超大图）。
      final declared = streamed.contentLength;
      if (declared != null && declared > kCoverDownloadLimitBytes) {
        await streamed.stream.drain<void>();
        return const ImageBytesNetwork();
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream) {
        builder.add(chunk);
        // 第二刀：无 Content-Length 头时按实际累计长度兜底。
        if (builder.length > kCoverDownloadLimitBytes) {
          return const ImageBytesNetwork();
        }
      }
      return ImageBytesOk(builder.takeBytes());
    } on TimeoutException {
      return const ImageBytesTimeout();
    } catch (_) {
      return const ImageBytesNetwork();
    }
  }
}

// 说明（task 3 指令的一条裁定，留作注释避免后来人重新踩）：
// * 「构造后不触发任何网络」没有直接断言：真内核是懒建的（见上），单测只测
//   注入 inner 的纯 outcome 路径；构造 impl 不传 inner 时一个 socket 都不开。
//   8MB 两条刀都可用 MockClient / MockClient.streaming 钉住，已测。

// ---------------------------------------------------------------------------
// matchCover 编排（Task 5）：查询 → 索引 → 两区搜索 → 落盘 → 状态。
// 对译 React matchCover（cover-source.js:368-396）去掉代理 / JSONP 分叉、
// 加上两区（music-api.ts:687-690 移进客户端）与落盘（music-api.ts:705-720
// 移进客户端）。空查询 / 索引命中 / not-found / 下载失败 / error 的语义
// 见 test/cover/cover_match_test.dart。
// ---------------------------------------------------------------------------

/// 一条曲目参与封面匹配所需的三个字段（[Track] 与最近播放记录都装得下）。
typedef CoverTrackLike = ({String title, String artist, double duration});

/// matchCover 的完整编排。永不抛错；失败一律以 [CoverMatch.status] 表达。
///
/// * 空查询（`normalizeQuery` 归一后 [LyricsQuery.trackName] 为空）→
///   `empty-query`，不发请求；
/// * [useCache] 且 [index] 命中（TTL 内）→ 直接返回缓存里的落盘路径；
/// * 未命中 → [itunesSearch] 两区搜索；ok → [CoverDiskStore.saveFromUrl]
///   落盘 → 索引写 `{p: 路径}` → 返回 ok+路径；**下载 / 落盘失败按
///   not-found 处理**（索引写 miss）—— 不返回半成品；
/// * 搜索 not-found → 索引写 miss；error / aborted 不写缓存。
Future<CoverMatch> matchCover(
  CoverTrackLike track, {
  required HttpJsonClient json,
  required ImageBytesClient bytes,
  required CoverDiskStore diskStore,
  CoverIndexCache? index,
  bool useCache = true,
}) async {
  final query = normalizeQuery(
    title: track.title,
    artist: track.artist,
    duration: track.duration,
  );
  if (query.trackName.isEmpty) {
    return const CoverMatch(status: 'empty-query');
  }
  if (useCache && index != null) {
    final cached = await index.read(query.key);
    if (cached != null) {
      return cached.isOk
          ? CoverMatch(status: 'ok', url: cached.path, source: cached.source)
          : const CoverMatch(status: 'not-found');
    }
  }
  try {
    final searched = await itunesSearch(
      query: (
        trackName: query.trackName,
        artistName: query.artistName,
        duration: query.duration.toDouble(),
      ),
      client: json,
    );
    if (searched.status == 'ok' && (searched.url?.isNotEmpty ?? false)) {
      final path = await diskStore.saveFromUrl(
        url: searched.url!,
        id: CoverDiskStore.cacheId(query.key),
        bytes: bytes,
      );
      if (path != null) {
        final record = CoverRecord(status: 'ok', path: path);
        await index?.write(query.key, record);
        return CoverMatch(status: 'ok', url: path, source: 'iTunes');
      }
      // 图下载 / 落盘失败：按 not-found 处理（写 miss），不返回半成品。
      await index?.write(query.key, const CoverRecord(status: 'not-found'));
      return const CoverMatch(status: 'not-found');
    }
    if (searched.status == 'not-found' || searched.status == 'empty-query') {
      await index?.write(query.key, const CoverRecord(status: 'not-found'));
      return const CoverMatch(status: 'not-found');
    }
    // error / aborted：不写缓存（网络错误不缓存，下次还值得一试）。
    return searched;
  } on RequestAborted {
    return const CoverMatch(status: 'aborted');
  } catch (_) {
    return const CoverMatch(status: 'error', message: '封面匹配失败');
  }
}
