import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/pending_proxy_selection.dart';
import 'package:hiddify/features/proxy/data/proxy_delay_cache.dart';
import 'package:hiddify/features/proxy/data/session_proxy_selection.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SelectedNodeSnapshot {
  const SelectedNodeSnapshot({required this.label, required this.delay});

  final String? label;
  final int delay;
}

final selectedNodeSnapshotProvider = FutureProvider.autoDispose<SelectedNodeSnapshot?>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return null;

  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  final pendingSelection = PendingProxySelectionStore.read(prefs, profile.id);
  final cachedDelays = ProxyDelayCacheStore.read(prefs, profile.id);
  final repo = ref.watch(profileRepositoryProvider).requireValue;

  String content;
  try {
    content = (await repo.generateConfig(profile.id).run()).match((_) => throw Exception(), (value) => value);
  } catch (_) {
    content = await repo.getRawConfig(profile.id).run().then((e) => e.getOrElse((_) => ""));
  }

  return _extractSelectedNodeSnapshot(content, pendingSelection, cachedDelays);
});

SelectedNodeSnapshot? _extractSelectedNodeSnapshot(
  String content,
  String? pendingSelection,
  Map<String, int> cachedDelays,
) {
  try {
    final jsonObject = jsonDecode(content);
    if (jsonObject is! Map<String, dynamic> || jsonObject['outbounds'] is! List) {
      return pendingSelection == null
          ? null
          : SelectedNodeSnapshot(label: pendingSelection, delay: cachedDelays[pendingSelection] ?? 0);
    }

    final outbounds = jsonObject['outbounds'] as List<dynamic>;
    final visibleTags = <String>[];
    String selectedTag = pendingSelection ?? "";

    for (final outbound in outbounds) {
      if (outbound is! Map<String, dynamic>) continue;
      final type = outbound['type']?.toString() ?? "";
      final tag = outbound['tag']?.toString() ?? "";
      if (tag.isEmpty || type.isEmpty) continue;

      if (type == 'selector' || type == 'urltest' || type == 'balancer') {
        final defaultTag = outbound['default']?.toString();
        if (selectedTag.isEmpty && defaultTag != null && defaultTag.isNotEmpty) {
          selectedTag = defaultTag;
        }
        continue;
      }

      if (type == 'dns' || type == 'block') continue;
      if (['direct', 'bypass', 'direct-fragment'].contains(tag)) continue;

      visibleTags.add(tag);
    }

    if (selectedTag.isNotEmpty && visibleTags.contains(selectedTag)) {
      return SelectedNodeSnapshot(label: selectedTag, delay: cachedDelays[selectedTag] ?? 0);
    }
    if (visibleTags.isNotEmpty) {
      final label = visibleTags.first;
      return SelectedNodeSnapshot(label: label, delay: cachedDelays[label] ?? 0);
    }
    return pendingSelection == null
        ? null
        : SelectedNodeSnapshot(label: pendingSelection, delay: cachedDelays[pendingSelection] ?? 0);
  } catch (_) {
    return pendingSelection == null
        ? null
        : SelectedNodeSnapshot(label: pendingSelection, delay: cachedDelays[pendingSelection] ?? 0);
  }
}

class SelectedNodeCard extends ConsumerWidget {
  const SelectedNodeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final serviceRunning = ref.watch(serviceRunningProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull));
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final sessionSelection = ref.watch(sessionProxySelectionProvider);
    final selectedThisSession = activeProfile != null && sessionSelection?.matchesProfile(activeProfile.id) == true
        ? sessionSelection!.outboundTag
        : null;
    final snapshot = ref.watch(selectedNodeSnapshotProvider).valueOrNull;

    final title = t.pages.proxies.title;
    final subtitle = serviceRunning ? t.connection.connected : "";
    final activeSnapshot = _activeProxySnapshot(activeProxy);
    final node =
        activeSnapshot ??
        (selectedThisSession == null
            ? null
            : SelectedNodeSnapshot(
                label: selectedThisSession,
                delay: snapshot?.label == selectedThisSession ? snapshot?.delay ?? 0 : 0,
              ));
    final nodeLabel = node?.label;
    final delay = node?.delay ?? 0;
    final hasNode = nodeLabel != null && nodeLabel.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.goNamed('proxies'),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 132),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface.withValues(alpha: 0.98),
                theme.colorScheme.primaryContainer.withValues(alpha: theme.brightness == Brightness.dark ? 0.22 : 0.5),
              ],
            ),
            border: Border.all(
              color: serviceRunning
                  ? theme.colorScheme.primary.withValues(alpha: 0.28)
                  : theme.colorScheme.outlineVariant,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.10),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.hub_rounded, color: theme.colorScheme.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (subtitle.isNotEmpty) _StatusPill(label: subtitle),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                hasNode ? nodeLabel : t.pages.proxies.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.12),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _DelayPill(delay: delay, timeoutLabel: t.common.timeout),
                  if (serviceRunning && activeSnapshot == null && snapshot != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      t.connection.connecting,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  const Spacer(),
                  Icon(Icons.arrow_forward_rounded, color: theme.colorScheme.primary, size: 22),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  SelectedNodeSnapshot? _activeProxySnapshot(OutboundInfo? activeProxy) {
    if (activeProxy == null) return null;
    final label = activeProxy.tagDisplay.trim().isNotEmpty ? activeProxy.tagDisplay : activeProxy.tag.trim();
    if (label.isEmpty) return null;
    return SelectedNodeSnapshot(label: label, delay: activeProxy.urlTestDelay);
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _DelayPill extends StatelessWidget {
  const _DelayPill({required this.delay, required this.timeoutLabel});

  final int delay;
  final String timeoutLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTimeout = delay > 65000;
    final hasDelay = delay > 0;
    final label = hasDelay ? (isTimeout ? timeoutLabel : "$delay ms") : "-- ms";
    final color = isTimeout
        ? theme.colorScheme.error
        : hasDelay
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}
