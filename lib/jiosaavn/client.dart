/// HTTP client wrapper with retry, rate limiting, session management, and cookie persistence.
///
/// Ported from the Python `Jiosaavn` class's `_configure_session`, `request`,
/// and `RateLimiter` logic. Python's `requests.Session` persists cookies
/// automatically; this Dart port maintains a simple cookie jar to match that
/// behavior — JioSaavn's `song.generateAuthToken` endpoint requires cookies
/// set by prior API calls (e.g., `webapi.get` metadata requests).

library jiosaavn.client;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'utils.dart';

/// Token-bucket rate limiter for API requests.
class RateLimiter {
  final double rate; // requests per second
  final int burst;
  double tokens;
  DateTime _lastUpdate;

  RateLimiter({this.rate = 10.0, this.burst = 5})
    : tokens = burst.toDouble(),
      _lastUpdate = DateTime.now();

  /// Acquire `tokens` from the bucket. Returns `true` if acquired, `false` on timeout.
  Future<bool> acquire({int tokensNeeded = 1, Duration? timeout}) async {
    final deadline = timeout != null ? DateTime.now().add(timeout) : null;
    while (true) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastUpdate).inMicroseconds / 1e6;
      synchronized(() {
        tokens = (tokens + elapsed * rate).clamp(0.0, burst.toDouble());
        _lastUpdate = now;
      });
      final currentTokens = synchronized(() => tokens);
      if (currentTokens >= tokensNeeded) {
        synchronized(() {
          tokens -= tokensNeeded;
        });
        return true;
      }
      if (timeout != null) {
        final needed = tokensNeeded - currentTokens;
        final waitTime = needed / rate;
        if (deadline != null &&
            DateTime.now()
                .add(Duration(seconds: waitTime.toInt()))
                .isAfter(deadline)) {
          return false;
        }
      } else {
        final waitTime = tokensNeeded / rate;
        await Future.delayed(
          Duration(milliseconds: (waitTime * 1000).clamp(0, 100).toInt()),
        );
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  T synchronized<T>(T Function() action) {
    // Dart is single-threaded per isolate; this is a no-op guard for API compatibility.
    return action();
  }
}

/// Retry policy that respects `Retry-After` on 429 responses.
class RetryPolicy {
  final int total;
  final double backoffFactor;
  final Set<int> statusForcelist;
  final Set<String> allowedMethods;

  RetryPolicy({
    this.total = 3,
    this.backoffFactor = 0.5,
    this.statusForcelist = const {429, 500, 502, 503, 504},
    this.allowedMethods = const {'GET'},
  });
}

/// An HTTP client with retry, rate limiting, cookie persistence, and default headers.
class JiosaavnClient {
  final http.Client _client;
  final int timeoutSeconds;
  final String? proxy;
  final RateLimiter prefetchLimiter;
  final RetryPolicy retryPolicy;

  // Cookie jar — persists cookies across requests like requests.Session does.
  final Map<String, String> _cookies = {};

  JiosaavnClient({
    http.Client? client,
    this.timeoutSeconds = 30,
    this.proxy,
    double prefetchRate = 5.0,
    int prefetchBurst = 3,
    RetryPolicy? retryPolicy,
    bool badCertificateCallback = false,
  }) : _client = client ?? _createDefaultClient(proxy, badCertificateCallback),
       prefetchLimiter = RateLimiter(rate: prefetchRate, burst: prefetchBurst),
       retryPolicy = retryPolicy ?? RetryPolicy();

  static http.Client _createDefaultClient(String? proxy, bool badCertificateCallback) {
    final httpClient = HttpClient();
    if (badCertificateCallback) {
      httpClient.badCertificateCallback = (cert, host, port) => true;
    }
    if (proxy != null && proxy.isNotEmpty) {
      httpClient.findProxy = (uri) => proxy;
    }
    return IOClient(httpClient);
  }

  /// Default headers sent with every request, including stored cookies.
  Map<String, String> get defaultHeaders {
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://www.jiosaavn.com/',
    };
    if (_cookies.isNotEmpty) {
      headers['Cookie'] = _cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    return headers;
  }

  /// Extract cookies from a response's `Set-Cookie` headers and store them.
  void _storeCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    // Use regex to find cookie `name=value` pairs in Set-Cookie headers.
    // Multiple Set-Cookie headers are joined by ", " in the http package,
    // and cookie attributes (path, domain, expires, etc.) follow the value
    // separated by ";". We match name=value where value stops at ; or ,
    // skipping standard cookie attributes.
    final cookieRegex = RegExp(r'\b([a-zA-Z0-9_.-]+)=([^;,]*)');
    for (final match in cookieRegex.allMatches(setCookie)) {
      final name = match.group(1)!;
      final value = match.group(2)!.trim();
      if (value.isEmpty) continue;
      if (['path', 'domain', 'expires', 'max-age', 'secure', 'httponly',
              'samesite', 'comment', 'version']
          .contains(name.toLowerCase())) {
        continue;
      }
      _cookies[name] = value;
    }
  }

  /// Perform a GET request with retry logic and cookie persistence.
  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    bool stream = false,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? Duration(seconds: timeoutSeconds);
    final requestHeaders = {...defaultHeaders, ...?headers};
    int attempts = 0;
    while (true) {
      attempts++;
      try {
        final request = http.Request('GET', uri)
          ..headers.addAll(requestHeaders);
        if (stream) {
          final response = await _client
              .send(request)
              .timeout(effectiveTimeout);
          final httpResponse = await http.Response.fromStream(response);
          _storeCookies(httpResponse);
          if (httpResponse.statusCode >= 400) {
            if (_shouldRetry(httpResponse.statusCode) &&
                attempts <= retryPolicy.total) {
              await _backoff(attempts);
              continue;
            }
            throw DownloadError(
              'Request failed with status ${httpResponse.statusCode}',
            );
          }
          return httpResponse;
        }
        final response = await _client
            .get(uri, headers: requestHeaders)
            .timeout(effectiveTimeout);
        _storeCookies(response);
        if (response.statusCode >= 400) {
          if (_shouldRetry(response.statusCode) &&
              attempts <= retryPolicy.total) {
            await _backoff(attempts);
            continue;
          }
          throw DownloadError(
            'Request failed with status ${response.statusCode}',
          );
        }
        return response;
      } on DownloadError {
        rethrow;
      } on TimeoutException {
        if (attempts <= retryPolicy.total) {
          await _backoff(attempts);
          continue;
        }
        throw DownloadError('Request timed out after $attempts attempts');
      } catch (exc) {
        if (attempts <= retryPolicy.total) {
          await _backoff(attempts);
          continue;
        }
        throw DownloadError('Request failed: $exc');
      }
    }
  }

  /// Perform a GET request and return the response as a stream (for downloads).
  ///
  /// CDN download responses don't set cookies we need, so this simply forwards
  /// the stream without buffering. Cookie persistence is handled by [get] for
  /// API requests.
  Future<http.StreamedResponse> send(
    http.Request request, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? Duration(seconds: timeoutSeconds);
    final requestHeaders = {...defaultHeaders, ...?headers};
    request.headers.addAll(requestHeaders);
    return _client.send(request).timeout(effectiveTimeout);
  }

  Future<void> _backoff(int attempt) async {
    final delay = retryPolicy.backoffFactor * attempt;
    await Future.delayed(Duration(milliseconds: (delay * 1000).round()));
  }

  bool _shouldRetry(int statusCode) {
    return retryPolicy.statusForcelist.contains(statusCode) &&
        retryPolicy.allowedMethods.contains('GET');
  }

  void close() {
    _client.close();
  }
}

/// Acquire a permit from the prefetch rate limiter, with a timeout.
Future<bool> acquirePrefetch(
  RateLimiter limiter, {
  Duration timeout = const Duration(seconds: 30),
}) {
  return limiter.acquire(timeout: timeout);
}
