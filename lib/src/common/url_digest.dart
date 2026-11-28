import 'dart:convert';

/// Stable digest of the public URL identity.
///
/// Content-affecting query parameters are retained in sorted order while
/// credentials and request-signing fields are removed. The digest therefore
/// distinguishes public variants such as `style=dark`/`style=light` without
/// persisting secrets or changing when a token rotates.
String digestPublicUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'u${_fnv1a64(url)}';

  final publicQuery = <String, List<String>>{};
  final keys = uri.queryParametersAll.keys.toList()..sort();
  for (final key in keys) {
    if (_isCredentialQueryParameter(key)) continue;
    publicQuery[key] = List<String>.of(uri.queryParametersAll[key]!)..sort();
  }
  final public = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: publicQuery.isEmpty ? null : publicQuery,
  ).toString();
  return 'u${_fnv1a64(public)}';
}

bool _isCredentialQueryParameter(String name) {
  final lower = name.toLowerCase();
  return lower == 'access_token' ||
      lower == 'access-token' ||
      lower == 'token' ||
      lower == 'api_key' ||
      lower == 'api-key' ||
      lower == 'apikey' ||
      lower == 'key' ||
      lower == 'signature' ||
      lower == 'sig' ||
      lower == 'expires' ||
      lower.startsWith('x-amz-') ||
      lower.startsWith('x-goog-');
}

/// FNV-1a 64-bit implemented with [BigInt] so the exact same 16-hex-digit
/// key is produced by native and JavaScript backends. This preserves all
/// cache keys written by the previous native integer implementation.
String _fnv1a64(String value) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
