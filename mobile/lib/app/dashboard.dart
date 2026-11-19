import 'dart:async';

import 'package:flutter/material.dart';

import 'account_pages.dart';
import 'app_model.dart';
import 'attendance_page.dart';
import 'classsweep_app.dart';
import 'photo_page.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.model});
  final AppModel model;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  Timer? _approvalPoll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _approvalPoll = Timer.periodic(const Duration(seconds: 6), (_) {
      if (widget.model.user?.status == 'pending' &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(widget.model.refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(widget.model.refresh());
  }

  @override
  void dispose() {
    _approvalPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  int _tab = 0;
  bool _signingOut = false;
  Future<void> _capture(Map<String, dynamic> session) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AttendancePage(model: widget.model, session: session),
      ),
    );
    await widget.model.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model, user = widget.model.user!;
    final status = switch (user.status) {
      'approved' =>
        model.faceReference != null
            ? 'Ready to check in'
            : model.preparingFace
            ? 'Preparing face check'
            : 'Face setup needs attention',
      'pending' => 'Awaiting review',
      'rejected' => 'Photo rejected',
      _ => 'Enrollment needed',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ClassSweep',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: model.refreshing ? null : model.refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(model: model),
              ),
            ),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_rounded),
            label: 'Check in',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: 'My attendance',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Account',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: model.refresh,
        child: PageBody(
          children: [
            if (model.refreshing) const LinearProgressIndicator(),
            if (model.refreshError != null) ErrorNotice(model.refreshError!),
            if (_tab == 0) ...[
              SectionTitle('Check in', ''),
              if (!user.approved || model.faceReference == null)
                _enrollment(status),
              const SectionTitle('Open sessions', ''),
              if (model.sessions.isEmpty)
                const InfoCard(
                  icon: Icons.event_available_outlined,
                  title: 'No open sessions',
                  body: 'Pull down to refresh.',
                ),
              for (final session in model.sessions)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session['title'] as String,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text('Closes ${displayTime(session['expires_at'])}'),
                        const SizedBox(height: 6),
                        Text(
                          session['gps'] is Map &&
                                  (session['gps'] as Map)['enabled'] == true
                              ? 'GPS required · within ${(session['gps'] as Map)['radius_m']} m'
                              : 'GPS not required',
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed:
                              user.approved &&
                                  model.faceReference != null &&
                                  !model.refreshing
                              ? () => _capture(session)
                              : null,
                          icon: const Icon(Icons.document_scanner_outlined),
                          label: const Text('Start check-in'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (_tab == 1) ...[
              const SectionTitle('Your attendance', ''),
              if (model.records.isEmpty)
                const InfoCard(
                  icon: Icons.receipt_long_outlined,
                  title: 'No recorded attendance yet',
                  body: '',
                ),
              for (final record in model.records)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.verified_outlined, color: teal),
                    title: Text(
                      record['title'] as String? ??
                          record['session_id'] as String,
                    ),
                    subtitle: Text(
                      '${displayTime(record['recorded_at'])}'
                      '${record['gps_status'] == 'passed'
                          ? '\nGPS passed · ${(record['location']['distance_m'] as num).toStringAsFixed(0)} m from center'
                          : record['gps_status'] == 'disabled'
                          ? '\nGPS not required'
                          : ''}',
                    ),
                  ),
                ),
            ],
            if (_tab == 2) ...[
              SectionTitle(user.name, 'Student ID · ${user.username}'),
              _enrollment(status),
              InfoCard(
                icon: Icons.dns_outlined,
                title: 'Connected server',
                body: model.serverUrl,
              ),
              OutlinedButton.icon(
                onPressed: _signingOut
                    ? null
                    : () async {
                        setState(() => _signingOut = true);
                        await model.signOut();
                      },
                icon: const Icon(Icons.logout),
                label: Text(_signingOut ? 'Signing out…' : 'Sign out'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _enrollment(String status) {
    final user = widget.model.user!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  user.approved
                      ? Icons.verified_user_outlined
                      : Icons.person_search_outlined,
                  color: teal,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.model.preparingFace) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (widget.model.facePreparationError != null) ...[
              const SizedBox(height: 8),
              Text(widget.model.facePreparationError!),
              TextButton(
                onPressed: widget.model.ensureFace,
                child: const Text('Retry face setup'),
              ),
            ],
            if (user.status == 'none' || user.status == 'rejected') ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PhotoPage(model: widget.model),
                    ),
                  );
                  await widget.model.refresh();
                },
                icon: const Icon(Icons.face_retouching_natural),
                label: const Text('Enroll my face'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
