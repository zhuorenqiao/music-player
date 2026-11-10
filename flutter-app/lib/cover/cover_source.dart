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
