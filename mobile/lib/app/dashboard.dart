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

class _DashboardState extends State<Dashboard> {
  int _tab = 0;
  bool _signingOut = false;
  Future<void> _capture([Map<String, dynamic>? session]) async {
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
      'approved' => 'Approved',
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
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: navy,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'YOUR CLASSROOM, VERIFIED',
                      style: TextStyle(
                        color: Color(0xff65ddd0),
                        fontSize: 11,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Hello, ${user.name}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      status,
                      style: const TextStyle(color: Color(0xffbed4de)),
                    ),
                  ],
                ),
              ),
              _enrollment(status),
              const SectionTitle(
                'Open sessions',
                'Choose your class, then scan the board’s two codes.',
              ),
              if (model.sessions.isEmpty)
                const InfoCard(
                  icon: Icons.event_available_outlined,
                  title: 'No open sessions',
                  body: 'Your instructor creates a session in the web dashboard. Pull down to refresh when the board codes appear.',
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
                          onPressed: user.approved && !model.refreshing
                              ? () => _capture(session)
                              : null,
                          icon: const Icon(Icons.document_scanner_outlined),
                          label: const Text('Start check-in'),
                        ),
                      ],
                    ),
                  ),
                ),
              const InfoCard(
                icon: Icons.phonelink_lock_rounded,
                title: 'Checks on your phone',
                body: 'Scan the board and match your enrolled face. If the instructor enables GPS, your phone also checks your distance from the classroom. Student coordinates stay on this phone; only processed results leave it.',
              ),
            ],
            if (_tab == 1) ...[
              const SectionTitle(
                'Your attendance',
                'Confirmed records from your classroom server.',
              ),
              if (model.records.isEmpty)
                const InfoCard(
                  icon: Icons.receipt_long_outlined,
                  title: 'No recorded attendance yet',
                  body: 'A record appears here only after the server accepts a completed check-in.',
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
              const InfoCard(
                icon: Icons.science_outlined,
                title: 'Experimental on-device checks',
                body: 'Camera, gyro and matching thresholds require validation on your Android phone. Head movement alone is not strong anti-spoof protection.',
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
            const SizedBox(height: 10),
            Text(switch (user.status) {
              'approved' => 'Prepare the approved face reference on this phone before the instructor purges the original photo.',
              'pending' => 'Your instructor is reviewing your one-time photo. Tap refresh after approval.',
              'rejected' => 'Take a new clear photo with one unobstructed face, then submit it for review.',
              _ => 'Upload a single photo for instructor review before your first check-in.',
            }, style: const TextStyle(height: 1.5, color: Color(0xff536e7a))),
            if (user.approved) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _capture(),
                icon: const Icon(Icons.download_done_outlined),
                label: const Text('Prepare on this phone'),
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
