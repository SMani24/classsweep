import 'package:flutter/material.dart';

import '../location/location.dart';
import 'app_model.dart';
import 'classsweep_app.dart';

/// Admin credentials and the pending center exist only in this page's state.
/// Available without student sign-in; all admin operations authenticate separately.
class InstructorPage extends StatefulWidget {
  const InstructorPage({super.key, required this.model, this.verifier});
  final AppModel model;
  final LocationVerifier? verifier;

  @override
  State<InstructorPage> createState() => _InstructorPageState();
}

class _InstructorPageState extends State<InstructorPage> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _title = TextEditingController();
  final _ttl = TextEditingController(text: '300');
  late final _verifier = widget.verifier ?? LocationVerifier();
  bool _gpsEnabled = false, _busy = false, _listed = false;
  double _radius = GpsPolicy.defaultRadiusM;
  GpsPolicy? _center;
  Map<String, dynamic>? _created;
  List<Map<String, dynamic>> _sessions = [];
  String? _error, _notice;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _title.dispose();
    _ttl.dispose();
    _center = null;
    _created = null;
    _sessions.clear();
    super.dispose();
  }

  bool _hasPassword() {
    if (_password.text.isNotEmpty) return true;
    setState(() => _error = 'Enter the instructor password.');
    return false;
  }

  void _start() {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
  }

  void _failed(Object error) {
    if (mounted) {
      setState(
        () =>
            _error = error is GpsFailure ? error.message : friendlyError(error),
      );
    }
  }

  /// Preview is explicit; creation always refreshes, even with a recent preview.
  Future<void> _capture() async {
    _start();
    setState(() => _center = null);
    try {
      final center = await _verifier.captureInstructor(_radius);
      if (mounted) setState(() => _center = center);
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    final title = _title.text.trim();
    final ttl = int.parse(_ttl.text.trim());
    _start();
    setState(() {
      _center = null;
      _created = null;
    });
    try {
      final center = _gpsEnabled
          ? await _verifier.captureInstructor(_radius)
          : const GpsPolicy.disabled();
      // A capture may finish after the page has been closed. Do not create then.
      if (!mounted) return;
      final result = await widget.model.api.createInstructorSession(
        _password.text,
        {'title': title, 'ttl_seconds': ttl, 'gps': center.toJson()},
      );
      if (!mounted) return;
      setState(() {
        _center = center.enabled ? center : null;
        _created = {...result, 'gps': center.toJson()};
        _notice =
            'Attendance session created. Display both codes in the classroom.';
        // Retain credentials for listing and disabling, only until page disposal.
      });
      await _loadSessions();
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSessions() async {
    final result = await widget.model.api.instructorSessions(_password.text);
    if (mounted) {
      setState(() {
        _sessions = result;
        _listed = true;
        for (final session in result) {
          if (session['id'] == _created?['id']) {
            _created = session;
            if (session['gps'] is Map && session['gps']['enabled'] == false) {
              _center = null;
            }
          }
        }
      });
    }
  }

  Future<void> _refresh() async {
    if (!_hasPassword()) return;
    _start();
    try {
      await _loadSessions();
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable(Map<String, dynamic> session) async {
    if (!_hasPassword()) return;
    _start();
    try {
      final id = session['id'] as String;
      await widget.model.api.disableSessionGps(_password.text, id);
      if (!mounted) return;
      setState(() {
        // Disable returns only {id,gps}; preserve the existing title and codes.
        _sessions = [
          for (final item in _sessions)
            if (item['id'] == id)
              {
                ...item,
                'gps': {'enabled': false},
              }
            else
              item,
        ];
        if (_created?['id'] == id) {
          _created = {
            ..._created!,
            'gps': {'enabled': false},
          };
          _center = null;
        }
        _notice = 'GPS is now disabled for this session. Students can retry without location.';
      });
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _activeSessions {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return _sessions.where((session) {
      final expires = session['expires_at'];
      return expires is num && expires.isFinite && expires > now;
    }).toList();
  }

  String _policyLabel(Object? json) {
    try {
      final policy = GpsPolicy.fromJson(json);
      return policy.enabled
          ? 'GPS on · ${policy.radiusM.round()} m radius · accuracy ±${policy.accuracyM!.toStringAsFixed(1)} m'
          : 'GPS off · no location required';
    } on GpsFailure {
      return 'GPS policy unavailable · refresh sessions';
    }
  }

  Widget _sessionCard(Map<String, dynamic> session, {bool created = false}) {
    final gps = session['gps'];
    final enabled = gps is Map && gps['enabled'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              created
                  ? 'Session created'
                  : '${session['title'] ?? 'Attendance session'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (created) ...[
              const SizedBox(height: 8),
              Text('${session['title'] ?? _title.text.trim()}'),
            ],
            const SizedBox(height: 12),
            // Wrapping keeps both codes readable on narrow phones and large text.
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                for (final key in ['code_a', 'code_b'])
                  if (session[key] != null)
                    SelectableText(
                      '${key == 'code_a' ? 'Code A' : 'Code B'}: ${session[key]}',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_policyLabel(gps)),
            if (enabled) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _disable(session),
                icon: const Icon(Icons.location_off_outlined),
                label: const Text('Disable GPS now'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Instructor sessions')),
    body: Form(
      key: _form,
      child: PageBody(
        children: [
          const SectionTitle(
            'Create attendance',
            'Create a code pair for a calibrated classroom. GPS is optional and off by default.',
          ),
          TextFormField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            autofillHints: const [],
            decoration: const InputDecoration(
              labelText: 'Instructor password',
              helperText: 'Kept only while this page is open.',
            ),
            validator: (value) => value == null || value.isEmpty
                ? 'Enter the instructor password.'
                : null,
          ),
          TextFormField(
            controller: _title,
            enabled: !_busy,
            maxLength: 150,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Session title'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a session title.'
                : null,
          ),
          TextFormField(
            controller: _ttl,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Session duration (seconds)',
              helperText: '30–1800 seconds. Default: 300 (5 minutes).',
            ),
            validator: (value) {
              final seconds = int.tryParse(value?.trim() ?? '');
              return seconds == null || seconds < 30 || seconds > 1800
                  ? 'Use a whole number from 30 to 1800.'
                  : null;
            },
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Require GPS for this session'),
            subtitle: const Text(
              'Students check distance on their phone. Only a distance and accuracy summary is sent.',
            ),
            value: _gpsEnabled,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _gpsEnabled = value;
                    _center = null;
                    _error = null;
                  }),
          ),
          if (_gpsEnabled) ...[
            Text(
              'Allowed radius: ${_radius.round()} m',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Slider(
              value: _radius,
              min: 25,
              max: 1000,
              divisions: 39,
              label: '${_radius.round()} m',
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _radius = value;
                      _center = null;
                    }),
            ),
            const Text(
              'Use current location for GPS. Stand at the classroom center. Creation always captures a fresh location; your phone may ask for permission.',
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _capture,
              icon: const Icon(Icons.my_location),
              label: const Text('Use current location for GPS'),
            ),
            if (_center != null)
              Text(
                'Preview accuracy: ±${_center!.accuracyM!.toStringAsFixed(1)} m · radius ${_center!.radiusM.round()} m. Location is refreshed when you create attendance.',
              ),
            Text(
              'Required accuracy: ±${(_radius / 2).clamp(0, 100).toStringAsFixed(1)} m or better. The server stores this session’s instructor center. No background tracking.',
            ),
          ],
          if (_busy) const LinearProgressIndicator(semanticsLabel: 'Working'),
          if (_error != null) ErrorNotice(_error!),
          if (_notice != null)
            Semantics(liveRegion: true, child: Text(_notice!)),
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.add),
            label: Text(_busy ? 'Working…' : 'Create attendance'),
          ),
          if (_created != null) _sessionCard(_created!, created: true),
          const SectionTitle(
            'Active sessions',
            'GPS can be disabled immediately for an active session. To change its center or radius, create a new session.',
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Load active sessions'),
          ),
          if (_listed && _activeSessions.isEmpty)
            const Text('No active sessions.'),
          for (final session in _activeSessions)
            if (session['id'] != _created?['id']) _sessionCard(session),
        ],
      ),
    ),
  );
}
