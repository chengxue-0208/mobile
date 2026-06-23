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
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SelectedNodeSnapshot {
  const SelectedNodeSnapshot({required this.label, required this.delay});

  final String? label;
  final int delay;
}

final disconnectedSelectedNodeProvider = FutureProvider.autoDispose<SelectedNodeSnapshot?>((ref) async {
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

    final title = t.pages.proxies.title;
    final subtitle = serviceRunning ? t.connection.connected : "";

    String? nodeLabel;
    int delay = 0;
    if (serviceRunning && activeProxy != null) {
      nodeLabel = activeProxy.tagDisplay;
      delay = activeProxy.urlTestDelay;
    } else {
      final snapshot = ref.watch(disconnectedSelectedNodeProvider).valueOrNull;
      nodeLabel = snapshot?.label;
      delay = snapshot?.delay ?? 0;
    }

    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.goNamed('proxies'),
        child: Container(
          width: double.infinity,
          height: 120,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 8),
              if (subtitle.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              const Spacer(),
              Text(
                nodeLabel ?? t.pages.proxies.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
              ),
              const Spacer(),
              Row(
                children: [
                  if (delay > 0)
                    Text(
                      delay > 65000 ? t.common.timeout : "$delay ms",
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: delay > 65000 ? theme.colorScheme.error : theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const Spacer(),
                  Icon(Icons.arrow_forward_rounded, color: theme.colorScheme.primary, size: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
