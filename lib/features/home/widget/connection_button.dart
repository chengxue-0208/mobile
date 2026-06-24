import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/session_proxy_selection.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull == true;
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final selectedNode = ref.watch(sessionProxySelectionProvider);
    final canStartConnection = activeProfile != null && selectedNode?.matchesProfile(activeProfile.id) == true;
    final today = DateTime.now();
    final presentation = _ConnectionButtonPresentation.from(
      connectionStatus: connectionStatus,
      canStartConnection: canStartConnection,
      requiresReconnect: requiresReconnect,
      translations: t,
    );

    return _ConnectionButton(
      onTap: _onTapFor(connectionStatus, requiresReconnect, canStartConnection, ref),
      enabled: presentation.enabled,
      label: presentation.label,
      buttonColor: presentation.buttonColor,
      image: presentation.image,
      animated: presentation.animated,
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
    );
  }

  VoidCallback _onTapFor(
    AsyncValue<ConnectionStatus> connectionStatus,
    bool requiresReconnect,
    bool canStartConnection,
    WidgetRef ref,
  ) {
    return switch (connectionStatus) {
      AsyncData(value: Connected()) when requiresReconnect => () => _reconnect(ref),
      AsyncData(value: Connected()) => () => ref.read(connectionNotifierProvider.notifier).toggleConnection(),
      AsyncData(value: Disconnected()) || AsyncError() when canStartConnection => () => _connect(ref),
      _ => () {},
    };
  }

  Future<void> _connect(WidgetRef ref) async {
    if (ref.read(activeProfileProvider).valueOrNull == null) {
      await ref.read(dialogNotifierProvider.notifier).showNoActiveProfile();
      ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
      return;
    }
    if (await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    }
  }

  Future<void> _reconnect(WidgetRef ref) async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
  }
}

class _ConnectionButtonPresentation {
  const _ConnectionButtonPresentation({
    required this.enabled,
    required this.label,
    required this.buttonColor,
    required this.image,
    required this.animated,
  });

  final bool enabled;
  final String label;
  final Color buttonColor;
  final AssetGenImage image;
  final bool animated;

  factory _ConnectionButtonPresentation.from({
    required AsyncValue<ConnectionStatus> connectionStatus,
    required bool canStartConnection,
    required bool requiresReconnect,
    required TranslationsEn translations,
  }) {
    const buttonTheme = ConnectionButtonTheme.light;
    final status = connectionStatus.valueOrNull;
    final isConnected = status == const Connected();
    final buttonColor = switch (status) {
      Connected() when requiresReconnect => Colors.teal,
      Connected() => buttonTheme.connectedColor!,
      ConnectionStatus() => buttonTheme.idleColor!,
      null => Colors.red,
    };

    return _ConnectionButtonPresentation(
      enabled:
          status == const Connected() ||
          ((connectionStatus is AsyncError || status == const Disconnected()) && canStartConnection),
      label: switch (status) {
        Connected() when requiresReconnect => translations.connection.reconnect,
        Disconnected() when !canStartConnection => translations.pages.proxies.title,
        ConnectionStatus() => status.present(translations),
        null when !canStartConnection => translations.pages.proxies.title,
        null => "",
      },
      buttonColor: buttonColor,
      image: isConnected && !requiresReconnect ? Assets.images.connectNorouz : Assets.images.disconnectNorouz,
      animated: status != null && !(isConnected && requiresReconnect),
    );
  }
}

class _ConnectionButton extends StatelessWidget {
  const _ConnectionButton({
    required this.onTap,
    required this.enabled,
    required this.label,
    required this.buttonColor,
    required this.image,
    required this.useImage,
    required this.animated,
  });

  final VoidCallback onTap;
  final bool enabled;
  final String label;
  final Color buttonColor;
  final AssetGenImage image;
  final bool useImage;

  final bool animated;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: label,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(blurRadius: 16, color: buttonColor.withValues(alpha: .5))],
            ),
            width: 148,
            height: 148,
            child: Material(
              key: const ValueKey("home_connection_button"),
              shape: const CircleBorder(),
              color: Colors.white,
              child: InkWell(
                focusColor: Colors.grey,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: TweenAnimationBuilder(
                    tween: ColorTween(end: buttonColor),
                    duration: const Duration(milliseconds: 250),
                    builder: (context, value, child) {
                      if (useImage) {
                        return image.image();
                      } else {
                        return Assets.images.logo.svg(colorFilter: ColorFilter.mode(value!, BlendMode.srcIn));
                      }
                    },
                  ),
                ),
              ),
            ).animate(target: enabled ? 0 : 1).blurXY(end: 1),
          ).animate(target: enabled ? 0 : 1).scaleXY(end: .88, curve: Curves.easeIn),
        ),
        const Gap(16),
        ExcludeSemantics(child: AnimatedText(label, style: Theme.of(context).textTheme.titleMedium)),
      ],
    );
  }
}
