import 'dart:async';
import 'dart:convert';

import 'package:dartx/dartx.dart';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/pending_proxy_selection.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_delay_cache.dart';
import 'package:hiddify/features/proxy/data/session_proxy_selection.dart';
import 'package:hiddify/features/settings/data/config_option_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxies_overview_notifier.g.dart';

enum ProxiesSort {
  unsorted,
  name,
  delay,
  usage;

  String present(TranslationsEn t) => switch (this) {
    ProxiesSort.unsorted => t.pages.proxies.sortOptions.unsorted,
    ProxiesSort.name => t.pages.proxies.sortOptions.name,
    ProxiesSort.delay => t.pages.proxies.sortOptions.delay,
    ProxiesSort.usage => t.pages.proxies.sortOptions.usage,
  };
}

@Riverpod(keepAlive: true)
class ProxiesSortNotifier extends _$ProxiesSortNotifier with AppLogger {
  late final _pref = PreferencesEntry(
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    key: "proxies_sort_mode",
    defaultValue: ProxiesSort.delay,
    mapFrom: ProxiesSort.values.byName,
    mapTo: (value) => value.name,
  );

  @override
  ProxiesSort build() {
    final sortBy = _pref.read();
    loggy.info("sort proxies by: [${sortBy.name}]");
    return sortBy;
  }

  Future<void> update(ProxiesSort value) {
    state = value;
    return _pref.write(value);
  }
}

@riverpod
class ProxiesOverviewNotifier extends _$ProxiesOverviewNotifier with AppLogger {
  @override
  Stream<OutboundGroup?> build() {
    ref.disposeDelay(const Duration(seconds: 15));
    final serviceRunning = ref.watch(serviceRunningProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    if (!serviceRunning) {
      return ref
          .watch(profileRepositoryProvider)
          .requireValue
          .watchActiveProfile()
          .map((event) => event.getOrElse((err) => throw err))
          .asyncMap((profile) async => await _buildProfileOutbounds(profile, sortBy));
    }
    // yield* ref
    //     .watch(proxyRepositoryProvider)
    //     .watchProxies()
    //     .throttleTime(
    //       const Duration(milliseconds: 100),
    //       leading: false,
    //       trailing: true,
    //     )
    //     .map(
    //       (event) => event.getOrElse(
    //         (err) {
    //           loggy.warning("error receiving proxies", err);
    //           throw err;
    //         },
    //       ),
    //     )
    //     .asyncMap((proxies) async => _sortOutbounds(proxies, sortBy));
    return ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        .map(
          (event) => event.getOrElse((err) {
            loggy.warning("error receiving proxies", err);
            throw err;
          }),
        )
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy));
  }

  Future<OutboundGroup?> _buildProfileOutbounds(ProfileEntity? profile, ProxiesSort sortBy) async {
    if (profile == null) return null;
    final profilesRepo = ref.read(profileRepositoryProvider).requireValue;
    final preferences = ref.read(sharedPreferencesProvider).requireValue;
    final pendingSelection = PendingProxySelectionStore.read(preferences, profile.id);
    final cachedDelays = ProxyDelayCacheStore.read(preferences, profile.id);

    String profContent;
    try {
      profContent = (await profilesRepo.generateConfig(profile.id).run()).match(
        (failure) => throw Exception('Failed to generate config: $failure'),
        (content) => content,
      );
    } catch (e, st) {
      loggy.warning('failed to generate config for disconnected proxy list', e, st);
      profContent = await profilesRepo.getRawConfig(profile.id).run().then((e) => e.getOrElse((_) => ""));
    }

    try {
      final jsonObject = jsonDecode(profContent);
      if (jsonObject is! Map<String, dynamic> || jsonObject['outbounds'] is! List) {
        return null;
      }

      final outboundsJson = jsonObject['outbounds'] as List<dynamic>;
      final items = <OutboundInfo>[];
      String selectedTag = "";

      for (final outbound in outboundsJson) {
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

        items.add(
          OutboundInfo(
            tag: tag,
            tagDisplay: tag,
            type: type,
            urlTestDelay: cachedDelays[tag] ?? 0,
            ipinfo: IpInfo(),
            isVisible: true,
            isSelected: false,
          ),
        );
      }

      if (items.isEmpty) return null;
      if (pendingSelection != null && items.any((item) => item.tag == pendingSelection)) {
        selectedTag = pendingSelection;
      }
      if (selectedTag.isEmpty && cachedDelays.isNotEmpty) {
        selectedTag = cachedDelays.entries
            .where((entry) => entry.value > 0)
            .map((entry) => entry.key)
            .toList()
            .reduce((a, b) => cachedDelays[a]! < cachedDelays[b]! ? a : b);
        final writeSuccess = await PendingProxySelectionStore.write(preferences, profile.id, selectedTag);
        if (!writeSuccess) {
          loggy.warning("failed to write pending proxy selection to cache: $selectedTag");
        }
      }
      for (final item in items) {
        item.isSelected = item.tag == selectedTag;
      }
      final fallbackGroup = OutboundGroup(
        tag: 'profile',
        type: 'selector',
        selected: selectedTag,
        selectable: false,
        items: items,
      );
      return await _sortOutbounds(fallbackGroup, sortBy);
    } catch (e, st) {
      loggy.error('error parsing disconnected proxy list', e, st);
      return null;
    }
  }

  Future<void> _persistDelayCache(String profileId, OutboundGroup group) async {
    final preferences = ref.read(sharedPreferencesProvider).requireValue;
    final delays = <String, int>{for (final item in group.items) item.tag: item.urlTestDelay};
    await ProxyDelayCacheStore.write(preferences, profileId, delays);
  }

  // Future<List<OutboundGroup>> _sortOutbounds(
  //   List<OutboundGroup> proxies,
  //   ProxiesSort sortBy,
  // ) async {
  //   final groupWithSelected = {
  //     for (final o in proxies) o.tag: o.selected,
  //   };
  //   final sortedProxies = <OutboundGroup>[];
  //   for (final group in proxies) {
  //     final sortedItems = switch (sortBy) {
  //       ProxiesSort.name => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;
  //           return a.tag.compareTo(b.tag);
  //         }),
  //       ProxiesSort.delay => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;

  //           final ai = a.urlTestDelay;
  //           final bi = b.urlTestDelay;
  //           if (ai == 0 && bi == 0) return -1;
  //           if (ai == 0 && bi > 0) return 1;
  //           if (ai > 0 && bi == 0) return -1;
  //           return ai.compareTo(bi);
  //         }),
  //       ProxiesSort.unsorted => group.items,
  //     };
  //     final items = <OutboundInfo>[];
  //     for (final item in sortedItems) {
  //       // if (groupWithSelected.keys.contains(item.tag)) {
  //       //   items.add(item.copyWith(selectedTag: groupWithSelected[item.tag]));
  //       // } else {
  //       items.add(item);
  //       // }
  //     }
  //     group.items.clear();
  //     group.items.addAll(items);
  //     sortedProxies.add(group);
  //   }
  //   return sortedProxies;
  // }

  Future<OutboundGroup?> _sortOutbounds(OutboundGroup? proxies, ProxiesSort sortBy) async {
    if (proxies == null) return null;

    final visibleItems = proxies.items.where((item) {
      final type = item.type.toLowerCase();
      return item.tag != 'lowest' && item.tag != 'balance' && type != 'urltest' && type != 'balancer';
    });

    // 过滤掉无法连接的节点（延迟为 0）
    final connectableItems = visibleItems.where((item) => item.urlTestDelay > 0);

    final sortedItems = switch (sortBy) {
      ProxiesSort.name => connectableItems.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return a.tag.compareTo(b.tag);
      }),
      ProxiesSort.delay => connectableItems.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return a.urlTestDelay.compareTo(b.urlTestDelay);
      }),
      ProxiesSort.unsorted => connectableItems,
      ProxiesSort.usage => connectableItems.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return (b.upload + b.download).compareTo(a.upload + a.download);
      }),
    };
    final items = <OutboundInfo>[];
    for (final item in sortedItems) {
      // if (groupWithSelected.keys.contains(item.tag)) {
      //   items.add(item.copyWith(selectedTag: groupWithSelected[item.tag]));
      // } else {
      items.add(item);
      // }
    }
    proxies.items.clear();
    proxies.items.addAll(items);
    return proxies;
  }

  // Future<void> changeProxy(String groupTag, String outboundTag) async {
  //   loggy.debug(
  //     "changing proxy, group: [$groupTag] - outbound: [$outboundTag]",
  //   );
  //   if (state case AsyncData(value: final outbounds)) {
  //     await ref.read(hapticServiceProvider.notifier).lightImpact();
  //     await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
  //       loggy.warning("error selecting outbound", err);
  //       throw err;
  //     }).run();
  //     final outboundg = outbounds.where((e) => e.tag == groupTag).firstOrNull;
  //     if (outboundg != null) {
  //       final newselected = outboundg.items.where((e) => e.tag == outboundTag).firstOrNull;
  //       if (newselected != null) {
  //         newselected.isSelected = true;
  //         outboundg.selected = newselected;
  //       }
  //     }
  //     state = AsyncData(
  //       [...outbounds],
  //     ).copyWithPrevious(state);
  //   }
  // }

  Future<void> changeProxy(String groupTag, String outboundTag) async {
    loggy.debug("changing proxy, group: [$groupTag] - outbound: [$outboundTag]");
    if (!state.hasValue) return;
    final outbounds = state.value!;
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) return;
    final preferences = ref.read(sharedPreferencesProvider).requireValue;
    final cachedDelays = ProxyDelayCacheStore.read(preferences, activeProfile.id);

    if (!ref.read(serviceRunningProvider)) {
      // 只允许选择可以连接的节点
      final delay = cachedDelays[outboundTag];
      if (delay == null || delay == 0) {
        loggy.warning("cannot select non-connectable node: $outboundTag");
        return;
      }
      await PendingProxySelectionStore.write(preferences, activeProfile.id, outboundTag);
      ref.read(sessionProxySelectionProvider.notifier).state = SessionProxySelection(
        profileId: activeProfile.id,
        outboundTag: outboundTag,
      );
      for (final item in outbounds.items) {
        item.isSelected = item.tag == outboundTag;
      }
      outbounds.selected = outboundTag;
      state = AsyncValue.data(outbounds);
      return;
    }

    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await PendingProxySelectionStore.write(preferences, activeProfile.id, outboundTag);
    ref.read(sessionProxySelectionProvider.notifier).state = SessionProxySelection(
      profileId: activeProfile.id,
      outboundTag: outboundTag,
    );
    final changedSelection = outbounds.selected != outboundTag;
    final newselected = outbounds.items.where((e) => e.tag == outboundTag).firstOrNull;
    if (newselected != null) {
      for (final item in outbounds.items) {
        item.isSelected = item.tag == outboundTag;
      }
      newselected.isSelected = true;
      outbounds.selected = newselected.tag;
      state = AsyncValue.data(outbounds);
    }
    if (changedSelection) {
      await ref.read(connectionNotifierProvider.notifier).abortConnection();
    }
  }

  Future<void> urlTest(String groupTag) async {
    loggy.debug("testing group: [$groupTag]");
    if (!state.hasValue) return;
    await ref.read(hapticServiceProvider.notifier).lightImpact();

    if (ref.read(serviceRunningProvider)) {
      await ref.read(proxyRepositoryProvider).urlTest(groupTag).getOrElse((err) {
        loggy.error("error testing group", err);
        throw err;
      }).run();
      final activeProfile = await ref.read(activeProfileProvider.future);
      final group = state.value;
      if (activeProfile != null && group != null) {
        await _persistDelayCache(activeProfile.id, group);
      }
      return;
    }

    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) return;

    final setupResult = await ref.read(connectionRepositoryProvider).setup().run();
    if (setupResult.isLeft()) return;

    final configOptions = ref.read(configOptionRepositoryProvider);
    final singbox = ref.read(hiddifyCoreServiceProvider);
    final optionsResult = configOptions.fullOptionsOverrided(activeProfile.profileOverride());
    final options = optionsResult.match((_) => null, (value) => value);
    if (options == null) return;

    final changeResult = await singbox.changeOptions(options).run();
    if (changeResult.isLeft()) return;

    final preview = await singbox
        .previewOutbounds(ref.read(profilePathResolverProvider).file(activeProfile.id).path, urlTestTag: groupTag)
        .run();
    final previewGroup = preview.getOrElse((_) => null);
    if (previewGroup == null) return;

    final sorted = await _sortOutbounds(previewGroup, ref.read(proxiesSortNotifierProvider));
    if (sorted != null) {
      await _persistDelayCache(activeProfile.id, sorted);
      state = AsyncValue.data(sorted);
    }
  }
}
