import 'package:hooks_riverpod/hooks_riverpod.dart';

class SessionProxySelection {
  const SessionProxySelection({required this.profileId, required this.outboundTag});

  final String profileId;
  final String outboundTag;

  bool matchesProfile(String profileId) => this.profileId == profileId;
}

final sessionProxySelectionProvider = StateProvider<SessionProxySelection?>((ref) => null);
