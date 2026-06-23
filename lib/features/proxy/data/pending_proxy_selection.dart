import 'package:shared_preferences/shared_preferences.dart';

abstract final class PendingProxySelectionStore {
  static const _keyPrefix = 'pending_proxy_selection.';

  static String? read(SharedPreferences preferences, String profileId) {
    final value = preferences.getString('$_keyPrefix$profileId');
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static Future<bool> write(SharedPreferences preferences, String profileId, String outboundTag) {
    return preferences.setString('$_keyPrefix$profileId', outboundTag);
  }

  static Future<bool> remove(SharedPreferences preferences, String profileId) {
    return preferences.remove('$_keyPrefix$profileId');
  }
}
