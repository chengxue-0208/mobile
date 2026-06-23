import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

abstract final class ProxyDelayCacheStore {
  static const _keyPrefix = 'proxy_delay_cache.';

  static Map<String, int> read(SharedPreferences preferences, String profileId) {
    final raw = preferences.getString('$_keyPrefix$profileId');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return const {};
      return map.map((key, value) => MapEntry(key.toString(), (value as num).toInt()));
    } catch (_) {
      return const {};
    }
  }

  static Future<bool> write(SharedPreferences preferences, String profileId, Map<String, int> delays) {
    return preferences.setString('$_keyPrefix$profileId', jsonEncode(delays));
  }
}
