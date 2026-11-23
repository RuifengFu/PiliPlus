import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:dio/dio.dart';

/// Lightweight reachability checks for CDN URLs.
///
/// A probe sends a 1-byte ranged GET and reads only the response headers.
/// Requests use the same headers as the player, so a URL that passes the
/// probe is a URL the player can open.
abstract final class CdnProbe {
  static Dio createDio(Duration timeout) =>
      Dio(
          BaseOptions(
            connectTimeout: timeout,
            receiveTimeout: timeout,
          ),
        )
        ..options.headers = {
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        };

  /// Returns the time to the response headers.
  /// Throws if the request fails, times out, or is cancelled.
  static Future<Duration> ttfb(
    Dio dio,
    String url, {
    required Duration timeout,
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final res = await dio
        .get<ResponseBody>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'range': 'bytes=0-0'},
          ),
        )
        .timeout(timeout);
    final elapsed = stopwatch.elapsed;
    // Only the headers matter here. Drop the body.
    unawaited(res.data!.stream.listen(null).cancel());
    return elapsed;
  }

  /// Probes all [urls] at the same time and returns the first one that
  /// responds successfully, or null if none does within [timeout].
  static Future<String?> race(
    List<String> urls, {
    required Duration timeout,
  }) async {
    if (urls.isEmpty) return null;
    final dio = createDio(timeout);
    final cancelToken = CancelToken();
    final winner = Completer<String?>();
    var pending = urls.length;
    for (final url in urls) {
      ttfb(dio, url, timeout: timeout, cancelToken: cancelToken).then(
        (_) {
          if (!winner.isCompleted) winner.complete(url);
        },
        onError: (_) {
          if (--pending == 0 && !winner.isCompleted) winner.complete(null);
        },
      );
    }
    try {
      return await winner.future.timeout(timeout, onTimeout: () => null);
    } finally {
      // Abort the losers and release their sockets.
      cancelToken.cancel();
      dio.close(force: true);
    }
  }
}
