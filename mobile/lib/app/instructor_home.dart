import 'package:flutter/material.dart';

import 'account_pages.dart';
import 'app_model.dart';
import 'classsweep_app.dart';
import 'instructor_page.dart';
import 'photo_page.dart';

class InstructorHome extends StatelessWidget {
  const InstructorHome({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    void open(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClassSweep'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: () => open(SettingsPage(model: model)),
          ),
        ],
      ),
      body: PageBody(
        children: [
          const SectionTitle('Instructor workspace', ''),
          if (model.refreshError != null) ErrorNotice(model.refreshError!),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.center_focus_strong_outlined,
                color: teal,
              ),
              title: const Text('Classroom calibration'),
              subtitle: const Text('Capture a reference view'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(PhotoPage(model: model, calibration: true)),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_available_outlined, color: teal),
              title: const Text('Attendance sessions'),
              subtitle: const Text('Create sessions and manage GPS'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(InstructorPage(model: model)),
            ),
          ),
          OutlinedButton.icon(
            onPressed: model.signOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
