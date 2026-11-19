import 'dart:math';

import 'package:flutter/material.dart';

import '../network/api_client.dart';
import 'app_model.dart';
import 'classsweep_app.dart';
import 'photo_page.dart';
import 'instructor_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.model});
  final AppModel model;
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _id = TextEditingController(),
      _password = TextEditingController();
  bool _instructor = false, _register = false, _busy = false, _obscure = true;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.authenticate(
        register: _register,
        instructor: _instructor,
        username: _instructor ? 'admin' : _id.text.trim(),
        password: _password.text,
        name: _name.text.trim(),
      );
      _password.clear();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'ClassSweep',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      actions: [
        IconButton(
          tooltip: 'Server settings',
          onPressed: _busy
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(model: widget.model),
                  ),
                ),
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    ),
    body: AutofillGroup(
      child: Form(
        key: _form,
        child: PageBody(
          children: [
            SectionTitle(
              _instructor ? 'Instructor sign-in' : 'Student access',
              '',
            ),
            if (!_instructor)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Sign in')),
                  ButtonSegment(value: true, label: Text('Create account')),
                ],
                selected: {_register},
                onSelectionChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _register = v.first;
                        _error = null;
                      }),
              ),
            if (_register)
              TextFormField(
                controller: _name,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                maxLength: 100,
                autofillHints: const [AutofillHints.name],
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter your name.' : null,
              ),
            if (!_instructor)
              TextFormField(
                controller: _id,
                enabled: !_busy,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Student ID',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                validator: (v) =>
                    RegExp(r'^[a-zA-Z0-9_.-]{3,64}$').hasMatch(v?.trim() ?? '')
                    ? null
                    : 'Use 3–64 letters or digits, . _ -',
              ),
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              autofillHints: [
                _register ? AutofillHints.newPassword : AutofillHints.password,
              ],
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (v) => v == null || v.isEmpty
                  ? 'Enter your password.'
                  : _register && (v.runes.length < 8 || v.runes.length > 256)
                  ? 'Use 8–256 characters.'
                  : null,
              onFieldSubmitted: (_) {
                if (!_busy) _submit();
              },
            ),
            if (_register)
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        final random = Random.secure();
                        const alphabet =
                            'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%+-_=';
                        setState(
                          () => _password.text = List.generate(
                            20,
                            (_) => alphabet[random.nextInt(alphabet.length)],
                          ).join(),
                        );
                      },
                icon: const Icon(Icons.password),
                label: const Text('Suggest strong password'),
              ),
            if (_error != null) ErrorNotice(_error!),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(
                _busy
                    ? 'Connecting…'
                    : _register
                    ? 'Create my account'
                    : 'Sign in',
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _instructor = !_instructor;
                      _register = false;
                      _error = null;
                      _password.clear();
                    }),
              child: Text(
                _instructor ? 'Student access' : 'Instructor sign-in',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.model});
  final AppModel model;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _url = TextEditingController(text: widget.model.serverUrl);
  bool _busy = false;
  bool _testing = false;
  String? _connectionResult;
  String? _error;
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.changeServer(_url.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _error = null;
      _connectionResult = null;
    });
    ClassSweepApi? probe;
    try {
      probe = ClassSweepApi(_url.text);
      await probe.testConnection();
      if (mounted) {
        setState(
          () => _connectionResult =
              'Connected to ClassSweep. You can save this address.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      probe?.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Connection & privacy')),
    body: PageBody(
      children: [
        const SectionTitle('Your classroom server', ''),
        TextField(
          controller: _url,
          enabled: !_busy && !_testing,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {
            _connectionResult = null;
            _error = null;
          }),
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://laptop.local:8000',
          ),
        ),
        if (_error != null) ErrorNotice(_error!),
        if (_connectionResult != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _connectionResult!,
              style: const TextStyle(color: teal),
            ),
          ),
        OutlinedButton.icon(
          onPressed: _busy || _testing ? null : _testConnection,
          icon: const Icon(Icons.wifi_find_rounded),
          label: Text(_testing ? 'Testing connection…' : 'Test connection'),
        ),
        FilledButton(
          onPressed: _busy || _testing ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save server'),
        ),
        const InfoCard(
          icon: Icons.wifi_rounded,
          title: 'Connect over Wi-Fi',
          body: 'Put both devices on the same Wi-Fi.',
        ),
        const InfoCard(
          icon: Icons.router_outlined,
          title: 'If the local name does not work',
          body: 'Use the IP address printed by the laptop server.',
        ),
        const Text(
          'Changing servers signs you out.',
          style: TextStyle(height: 1.5),
        ),
        const InfoCard(
          icon: Icons.shield_outlined,
          title: 'Images stay local during attendance',
          body: 'Your instructor reviews the front enrollment photo. Check-ins send results only.',
        ),
        Text(
          'Device binding · ${widget.model.deviceId.isEmpty ? 'Unavailable' : widget.model.deviceId.substring(0, 12)}…',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (widget.model.user?.isInstructor == true)
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PhotoPage(model: widget.model, calibration: true),
                    ),
                  ),
            icon: const Icon(Icons.meeting_room_outlined),
            label: const Text('Instructor calibration'),
          ),
        if (widget.model.user?.isInstructor == true)
          OutlinedButton.icon(
            onPressed: _busy || _testing
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => InstructorPage(model: widget.model),
                    ),
                  ),
            icon: const Icon(Icons.event_note_outlined),
            label: const Text('Instructor attendance & GPS'),
          ),
      ],
    ),
  );
}
