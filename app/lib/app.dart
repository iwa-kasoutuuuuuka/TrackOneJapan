import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/notifications/phone_notifier.dart';
import 'core/state/auth.dart';
import 'core/state/theme_mode.dart';
import 'core/theme.dart';
import 'features/alarms/alarm_detail_page.dart';
import 'features/home/home_page.dart';
import 'features/login/login_page.dart';

/// 通知をタップしたときに画面を開くための鍵
final navigatorKey = GlobalKey<NavigatorState>();

class TrackOneApp extends ConsumerStatefulWidget {
  const TrackOneApp({super.key});

  @override
  ConsumerState<TrackOneApp> createState() => _TrackOneAppState();
}

class _TrackOneAppState extends ConsumerState<TrackOneApp> {
  @override
  void initState() {
    super.initState();
    PhoneNotifier.instance.onTap = (eventId) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => AlarmDetailPage(eventId: eventId)));
    };
    PhoneNotifier.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'TrackOne Japan',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('ja', 'JP'),
      supportedLocales: const [Locale('ja', 'JP')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _AuthGate(),
    );
  }
}

/// ログイン状態に応じて、ログイン画面かホームを表示
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return auth.when(
      loading: () => const _Splash(),
      error: (e, _) => _OfflineView(
        message: e.toString(),
        onRetry: () => ref.read(authProvider.notifier).retry(),
        onForget: () => ref.read(authProvider.notifier).forgetSavedLogin(),
      ),
      data: (session) => session == null ? const LoginPage() : const HomePage(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.navy,
        body: Center(child: Image.asset('assets/icon/icon-foreground.png', width: 200, height: 200)),
      );
}

class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.message, required this.onRetry, required this.onForget});
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/icon/icon-512.png', width: 72),
              const SizedBox(height: 18),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              FilledButton(onPressed: onRetry, child: const Text('もう一度試す')),
              const SizedBox(height: 8),
              // サーバーの URL が変わった・使わなくなったときに、ログイン画面へ戻れるように
              TextButton(onPressed: onForget, child: const Text('別のサーバー・アカウントでログイン')),
            ]),
          ),
        ),
      );
}
