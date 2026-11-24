// lib/lyrics/page_client.dart
//
// 少数歌词源（汽水音乐）需要直接抓分享页 HTML，而不是 JSON 接口。
// HttpJsonClient 只解 JSON，这里单独开一个「取文本」的接缝；测试注入假实现，
// 生产复用同一个 package:http Client。
//
// 汽水分享页对 UA 很敏感：桌面 UA 会落到 404 / 空壳（没有 _ROUTER_DATA），
// 必须用移动端 UA 才拿得到带歌词的服务端渲染数据。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 只发 GET、返回 UTF-8 文本的接缝；失败（超时 / 状态码非 2xx / 网络）一律 null。
abstract class LyricsPageClient {
  Future<String?> getPage(Uri url, {required Duration timeout});
}

/// 生产实现：package:http 直连，懒建内核（理由同 HttpJsonClientImpl）。
class HttpPageClient implements LyricsPageClient {
  HttpPageClient({http.Client? inner}) : _explicitInner = inner;

  final http.Client? _explicitInner;
  http.Client? _lazyInner;

  http.Client get _inner => _explicitInner ?? (_lazyInner ??= http.Client());

  /// 汽水分享页认移动端 UA；桌面 UA 会拿到没有歌词数据的空壳。
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  @override
  Future<String?> getPage(Uri url, {required Duration timeout}) async {
    try {
      final response = await _inner.get(url, headers: _headers).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
