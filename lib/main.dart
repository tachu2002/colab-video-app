import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'store.dart';
import 'page_connect.dart';
import 'page_generate.dart';
import 'page_history.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();
  runApp(App(state: state));
}

class App extends StatelessWidget {
  final AppState state;
  const App({super.key, required this.state});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '動画生成',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ja', 'JP'),
        supportedLocales: const [Locale('ja', 'JP')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'NotoSansJP', // 全体を日本語の書体に統一（無い場合は端末の標準）
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C9CFF), brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF14171D),
        ),
        home: Home(state: state),
      );
}

class Home extends StatefulWidget {
  final AppState state;
  const Home({super.key, required this.state});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    WidgetsBinding.instance.addObserver(this);
    widget.state.refreshFromDrive();
    // 接続情報がまだ無ければ接続タブから始める
    tab = widget.state.status == null ? 0 : 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_onState);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) widget.state.refreshFromDrive();
  }

  void _onState() {
    if (widget.state.requestedTab >= 0) {
      setState(() => tab = widget.state.requestedTab);
      widget.state.requestedTab = -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: tab, children: [
          ConnectPage(state: s),
          GeneratePage(state: s),
          HistoryPage(state: s),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.cloud_outlined), label: '接続'),
          NavigationDestination(icon: Icon(Icons.movie_creation_outlined), label: '生成'),
          NavigationDestination(icon: Icon(Icons.history), label: '履歴'),
        ],
      ),
    );
  }
}
