import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../location/location.dart';
import 'app_model.dart';
import 'classsweep_app.dart';

/// Session controls use the active instructor sign-in.
class InstructorPage extends StatefulWidget {
  const InstructorPage({super.key, required this.model, this.verifier});
  final AppModel model;
  final LocationVerifier? verifier;

  @override
  State<InstructorPage> createState() => _InstructorPageState();
}

class _InstructorPageState extends State<InstructorPage> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _codeA = TextEditingController(), _codeB = TextEditingController();
  final _ttl = TextEditingController(text: '300');
  late final _verifier = widget.verifier ?? LocationVerifier();
  bool _overrideCodes = false;
  bool _gpsEnabled = false, _busy = false, _listed = false;
  double _radius = GpsPolicy.defaultRadiusM;
  GpsPolicy? _center;
  Map<String, dynamic>? _created;
  List<Map<String, dynamic>> _sessions = [];
  String? _error, _notice;

  @override
  void dispose() {
    _title.dispose();
    _codeA.dispose();
    _codeB.dispose();
    _ttl.dispose();
    _center = null;
    _created = null;
    _sessions.clear();
    super.dispose();
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
    final testCodes = _overrideCodes
        ? {'code_a': _codeA.text, 'code_b': _codeB.text}
        : const <String, String>{};
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
      final result = await widget.model.api.createInstructorSession({
        'title': title,
        'ttl_seconds': ttl,
        'gps': center.toJson(),
        ...testCodes,
      });
      if (!mounted) return;
      setState(() {
        _center = center.enabled ? center : null;
        _created = result;
        _sessions = [
          result,
          ..._sessions.where((item) => item['id'] != result['id']),
        ];
        _notice =
            'Attendance session created. Display both codes in the classroom.';
      });
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSessions() async {
    final result = await widget.model.api.instructorSessions();
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
    _start();
    try {
      final id = session['id'] as String;
      await widget.model.api.disableSessionGps(id);
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

  Future<void> _close(Map<String, dynamic> session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close this session?'),
        content: const Text('Check-ins will end. Recorded attendance is kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close session'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy) return;
    final id = session['id'] as String;
    _start();
    try {
      await widget.model.api.closeInstructorSession(id);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions.where((item) => item['id'] != id).toList();
        if (_created?['id'] == id) {
          _created = null;
          _center = null;
        }
        _notice = 'Session closed. The test codes can be reused.';
      });
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isActive(Map<String, dynamic> session) {
    final expires = session['expires_at'];
    return expires is num &&
        expires.isFinite &&
        expires > DateTime.now().millisecondsSinceEpoch / 1000;
  }

  List<Map<String, dynamic>> get _activeSessions =>
      _sessions.where(_isActive).toList();

  Widget _codeField(
    String label,
    TextEditingController controller, {
    bool second = false,
  }) => TextFormField(
    controller: controller,
    enabled: !_busy,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(4),
    ],
    decoration: InputDecoration(labelText: label, counterText: ''),
    validator: (value) {
      if (value == null || !RegExp(r'^[0-9]{4}$').hasMatch(value)) {
        return 'Enter 4 digits.';
      }
      if (second && value == _codeA.text) return 'Use a different code.';
      return null;
    },
  );

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
    final active = _isActive(session);
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
            if (active) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (enabled)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _disable(session),
                      icon: const Icon(Icons.location_off_outlined),
                      label: const Text('Disable GPS now'),
                    ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _close(session),
                    child: const Text('Close session'),
                  ),
                ],
              ),
            ] else
              const Text('Session closed'),
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
          const SectionTitle('Create attendance', ''),
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
            subtitle: const Text('Student coordinates stay on their phone.'),
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
            const Text('Stand near the center of the room.'),
            OutlinedButton.icon(
              onPressed: _busy ? null : _capture,
              icon: const Icon(Icons.my_location),
              label: const Text('Use current location for GPS'),
            ),
            if (_center != null)
              Text(
                'Preview accuracy: ±${_center!.accuracyM!.toStringAsFixed(1)} m.',
              ),
            Text(
              'Required accuracy: ±${(_radius / 2).clamp(0, 100).toStringAsFixed(1)} m or better.',
            ),
          ],
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Override board codes for testing'),
            subtitle: const Text('Random codes are used by default.'),
            value: _overrideCodes,
            onChanged: _busy
                ? null
                : (value) => setState(() => _overrideCodes = value),
          ),
          if (_overrideCodes) ...[
            _codeField('First code', _codeA),
            _codeField('Second code', _codeB, second: true),
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
          const SectionTitle('Active sessions', ''),
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
