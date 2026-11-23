import 'dart:async';

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget? Function(BuildContext context, int index, T value)?
  subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(item.$2, style: titleMedium),
                    subtitle: subtitleBuilder?.call(context, index, item.$1),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;

  const CdnSelectDialog({
    super.key,
    this.sample,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

/// The speed test runs in two phases:
/// 1. Probe every CDN at once with a 1-byte request, so unreachable CDNs
///    fail within [_timeout] instead of blocking the others.
/// 2. Measure throughput of the reachable CDNs, lowest latency first, at most
///    [_speedConcurrency] at a time so they do not share bandwidth.
class _CdnSelectDialogState extends State<CdnSelectDialog> {
  static const _timeout = Duration(seconds: 5);
  static const _speedConcurrency = 2;
  static const _speedMaxBytes = 8 * 1024 * 1024;
  static const _speedMaxDuration = Duration(seconds: 6);

  late final List<ValueNotifier<String?>> _cdnResList;
  late final List<CancelToken> _tokens;
  late final bool _cdnSpeedTest;
  late final Dio _dio;

  @override
  void initState() {
    _cdnSpeedTest = Pref.cdnSpeedTest;
    if (_cdnSpeedTest) {
      _dio = CdnProbe.createDio(_timeout);
      final length = CDNService.values.length;
      _cdnResList = List.generate(
        length,
        (_) => ValueNotifier<String?>(null),
      );
      _tokens = List.generate(length, (_) => CancelToken());
      _startSpeedTest();
    }
    super.initState();
  }

  @override
  void dispose() {
    if (_cdnSpeedTest) {
      for (final e in _tokens) {
        e.cancel();
      }
      for (final notifier in _cdnResList) {
        notifier.dispose();
      }
      _dio.close(force: true);
    }
    super.dispose();
  }

  Future<BaseItem> _getSampleUrl() async {
    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    final item = result.dataOrNull?.dash?.video?.first;
    if (item == null) throw Exception('无法获取视频流');
    return item;
  }

  Future<void> _startSpeedTest() async {
    try {
      final videoItem = widget.sample ?? await _getSampleUrl();
      await _testAllCdnServices(videoItem);
    } catch (e) {
      if (kDebugMode) debugPrint('CDN speed test failed: $e');
    }
  }

  Future<void> _testAllCdnServices(BaseItem videoItem) async {
    // Auto picks a URL per video at playback time. There is no fixed URL
    // to measure.
    _setResult(CDNService.auto.index, '播放时自动选择');
    final items = CDNService.values.where((e) => e != CDNService.auto);
    final urls = [
      for (final item in CDNService.values)
        VideoUtils.getCdnUrl(videoItem.playUrls, defaultCDNService: item),
    ];

    // Phase 1: probe every CDN concurrently.
    final latencies = List<Duration?>.filled(CDNService.values.length, null);
    await Future.wait([
      for (final item in items)
        _probe(
          urls[item.index],
          item.index,
        ).then((latency) => latencies[item.index] = latency),
    ]);
    if (!mounted) return;

    // Phase 2: measure throughput of reachable CDNs, lowest latency first.
    final queue = [
      for (final item in items)
        if (latencies[item.index] != null) item.index,
    ]..sort((a, b) => latencies[a]!.compareTo(latencies[b]!));

    var next = 0;
    Future<void> worker() async {
      while (mounted && next < queue.length) {
        final index = queue[next++];
        await _measureSpeed(urls[index], index, latencies[index]!);
      }
    }

    await Future.wait(List.generate(_speedConcurrency, (_) => worker()));
  }

  /// Returns the time to first byte, or null when the CDN is unusable.
  Future<Duration?> _probe(String url, int index) async {
    try {
      final latency = await CdnProbe.ttfb(
        _dio,
        url,
        timeout: _timeout,
        cancelToken: _tokens[index],
      );
      _setResult(index, '${latency.inMilliseconds}ms · 等待测速');
      return latency;
    } catch (e) {
      // Release a request that outlived the timeout; phase 2 skips this CDN.
      _tokens[index].cancel();
      _setResult(index, _errorText(e));
      return null;
    }
  }

  Future<void> _measureSpeed(String url, int index, Duration latency) async {
    final prefix = '${latency.inMilliseconds}ms';
    _setResult(index, '$prefix · 测速中…');

    final stopwatch = Stopwatch();
    int received = 0;
    try {
      final res = await _dio.get<ResponseBody>(
        url,
        cancelToken: _tokens[index],
        options: Options(
          responseType: ResponseType.stream,
          // Some CDNs (e.g. cosov) answer a full-file GET with HTTP 567.
          headers: {'range': 'bytes=0-${_speedMaxBytes - 1}'},
        ),
      );
      stopwatch.start();
      await for (final chunk in res.data!.stream) {
        received += chunk.length;
        if (!mounted ||
            received >= _speedMaxBytes ||
            stopwatch.elapsed >= _speedMaxDuration) {
          break;
        }
      }
    } catch (e) {
      if (received == 0) {
        _setResult(index, '$prefix · ${_errorText(e)}');
        return;
      }
      // Stalled mid-download: report the partial speed below.
    } finally {
      _tokens[index].cancel();
    }

    final micros = stopwatch.elapsedMicroseconds;
    if (micros == 0) return;
    // bytes per microsecond == MB/s
    final speed = (received / micros).toStringAsPrecision(3);
    _setResult(index, '$prefix · ${speed}MB/s');
  }

  void _setResult(int index, String value) {
    if (mounted) _cdnResList[index].value = value;
  }

  static String _errorText(Object error) {
    if (kDebugMode) debugPrint('CDN speed test error: $error');
    if (error is TimeoutException) return '连接超时';
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null && 400 <= statusCode && statusCode < 500) {
        return '此视频可能无法替换为该CDN';
      }
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout => '连接超时',
        DioExceptionType.connectionError => '无法连接',
        DioExceptionType.badResponse => 'HTTP $statusCode',
        _ => error.message ?? '测速失败',
      };
    }
    final text = error.toString();
    return text.isEmpty ? '测速失败' : text;
  }

  @override
  Widget build(BuildContext context) {
    return SelectDialog<CDNService>(
      title: 'CDN 设置',
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index, type) {
              final item = _cdnResList[index];
              return ValueListenableBuilder(
                valueListenable: item,
                builder: (context, value, _) {
                  return Text(
                    value ?? '---',
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            }
          : null,
    );
  }
}
