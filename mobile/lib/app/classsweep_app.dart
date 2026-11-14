import 'package:flutter/material.dart';

import 'app_model.dart';
import 'account_pages.dart';
import 'dashboard.dart';

const navy = Color(0xff102e3e);
const teal = Color(0xff087f8c);

class ClassSweepApp extends StatefulWidget {
  const ClassSweepApp({super.key, this.model});
  final AppModel? model;
  @override
  State<ClassSweepApp> createState() => _ClassSweepAppState();
}

class _ClassSweepAppState extends State<ClassSweepApp> {
  late final AppModel model = widget.model ?? AppModel();
  @override
  void initState() {
    super.initState();
    model.initialize();
  }

  @override
  void dispose() {
    if (widget.model == null) model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ClassSweep',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        primary: teal,
        secondary: navy,
        surface: const Color(0xfff7fafb),
      ),
      scaffoldBackgroundColor: const Color(0xfff7fafb),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff7fafb),
        foregroundColor: navy,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xffd5e2e6)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xffd5e2e6)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xffe0e9ec)),
        ),
      ),
    ),
    home: AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (model.booting) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.radar_rounded, size: 56, color: teal),
                  SizedBox(height: 20),
                  Text('Opening ClassSweep'),
                  SizedBox(height: 20),
                  CircularProgressIndicator(),
                ],
              ),
            ),
          );
        }
        if (model.bootError != null) {
          return Scaffold(
            appBar: AppBar(title: const Text('ClassSweep')),
            body: PageBody(
              children: [
                const SectionTitle(
                  'Could not open private storage',
                  'Your account needs private device storage to continue.',
                ),
                ErrorNotice(model.bootError!),
                FilledButton(
                  onPressed: model.initialize,
                  child: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        return model.session == null
            ? AuthPage(model: model)
            : Dashboard(model: model);
      },
    ),
  );
}

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 36),
        children: [
          for (final child in children)
            Padding(padding: const EdgeInsets.only(bottom: 18), child: child),
        ],
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w700, color: navy),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: const TextStyle(color: Color(0xff536e7a), height: 1.5),
      ),
    ],
  );
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}

class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: teal),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: const TextStyle(
                    height: 1.45,
                    color: Color(0xff536e7a),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String displayTime(dynamic value) {
  if (value is! num) return 'Time unavailable';
  final time = DateTime.fromMillisecondsSinceEpoch((value * 1000).round())
      .toLocal();
  return '${time.year}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')} · ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
