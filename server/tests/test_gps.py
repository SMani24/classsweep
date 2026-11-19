"""GPS protocol tests use only disposable SQLite databases and an injected clock."""
import csv
import io
import json
import sqlite3

import pytest
from fastapi.testclient import TestClient

from classsweep.app import create_app
from classsweep.storage import Database, password_hash
from test_api import (ADMIN_PASSWORD, DEVICE, PASSWORD, account, admin, approved_account,
                      attempt, env, result, room, session)


def policy(clock, **updates):
    return {"enabled": True, "latitude": 35.7, "longitude": 51.4,
            "accuracy_m": 20.0, "captured_at": clock[0], "radius_m": 100.0, **updates}


def gps_session(client, clock, **updates):
    room(client)
    response = client.post('/admin/sessions', json={"title": "GPS lecture", "gps": policy(clock, **updates)},
                           **admin(client))
    assert response.status_code == 201, response.text
    return response.json()


def submit(client, headers, sha, lecture, location):
    challenge = attempt(client, headers, sha, lecture)
    assert challenge.status_code == 201, challenge.text
    body = result(challenge.json(), sha)
    if location is not None:
        body['location'] = location
    return client.post('/api/attendance', headers=headers, json=body), body


def test_enabled_policy_discovery_and_summary_only_storage_export(env):
    client, app, clock = env
    _, headers, sha = approved_account(client)
    lecture = gps_session(client, clock)
    assert lecture['gps'] == policy(clock)
    for path in ('/api/sessions', f'/api/sessions/{lecture["id"]}'):
        assert client.get(path).status_code == 401
        response = client.get(path, headers=headers)
        item = response.json()[0] if path == '/api/sessions' else response.json()
        assert item['gps'] == policy(clock)
        assert 'code_a' not in item and 'gps_json' not in item
    response = client.get('/admin/sessions', auth=('admin', ADMIN_PASSWORD))
    assert response.json()[0]['gps'] == lecture['gps']
    assert response.json()[0]['code_a'] == lecture['code_a']
    summary = {'distance_m': 42.0, 'accuracy_m': 12.0, 'captured_at': clock[0]}
    response, body = submit(client, headers, sha, lecture, summary)
    assert response.status_code == 201, response.text
    expected = {'distance_m': 42.0, 'accuracy_m': 12.0}
    assert response.json()['gps_status'] == 'passed'
    assert response.json()['location'] == expected
    history = client.get('/api/attendance', headers=headers).json()[0]
    assert history['gps_status'] == 'passed' and history['location'] == expected
    with app.state.db.connect() as conn:
        row = conn.execute('SELECT * FROM attendance').fetchone()
        assert json.loads(row['gps_json']) == {'status': 'passed', **expected}
        assert json.loads(row['metrics']) == body['metrics']
        assert json.loads(row['checks']) == body['checks']
        assert not any(key in row['gps_json'] for key in ('latitude', 'longitude', 'captured_at'))
    exported = client.get(f'/admin/sessions/{lecture["id"]}/results.csv', auth=('admin', ADMIN_PASSWORD))
    row = list(csv.DictReader(io.StringIO(exported.text)))[0]
    assert row['gps_status'] == 'passed' and float(row['gps_distance_m']) == 42
    assert float(row['gps_accuracy_m']) == 12
    assert json.loads(row['metrics_json']) == body['metrics']
    assert not any(key in exported.text for key in ('latitude', 'longitude', 'captured_at'))


def test_policy_schema_and_center_validation(env):
    client, _, clock = env
    room(client)
    credentials = admin(client)
    invalid = [
        {'enabled': False, 'latitude': 0}, {'enabled': False, 'longitude': 0},
        {'enabled': False, 'radius_m': 100}, {'enabled': False, 'captured_at': clock[0]},
        {'enabled': False, 'accuracy_m': 1}, {'enabled': 0}, {'enabled': 1},
        {'enabled': 'true'}, {}, None,
        policy(clock, latitude=-90.001), policy(clock, latitude=90.001),
        policy(clock, longitude=-180.001), policy(clock, longitude=180.001),
        policy(clock, radius_m=24.999), policy(clock, radius_m=1000.001),
        policy(clock, radius_m=True), policy(clock, radius_m='100'),
        policy(clock, accuracy_m=-0.001), policy(clock, accuracy_m=50.001),
        policy(clock, radius_m=1000, accuracy_m=100.001),
        policy(clock, radius_m=25, accuracy_m=12.501),
        policy(clock, captured_at=clock[0]-60.001), policy(clock, captured_at=clock[0]+15.001),
        policy(clock, latitude=True), policy(clock, longitude='51.4'),
    ]
    for field in ('latitude', 'longitude', 'accuracy_m', 'captured_at', 'radius_m'):
        for number in (float('nan'), float('inf'), -float('inf')):
            invalid.append(policy(clock, **{field: number}))
    for gps in invalid:
        response = client.post('/admin/sessions', content=json.dumps({'title': 'Invalid', 'gps': gps}),
                               auth=credentials['auth'],
                               headers={**credentials['headers'], 'Content-Type': 'application/json'})
        assert response.status_code == 422, (gps, response.text)
    # Inclusive coordinate, time, radius and accuracy boundaries; default radius.
    for gps in (policy(clock, latitude=-90, longitude=-180, radius_m=25, accuracy_m=12.5,
                       captured_at=clock[0]-60),
                policy(clock, latitude=90, longitude=180, radius_m=1000, accuracy_m=100,
                       captured_at=clock[0]+15),
                {k: v for k, v in policy(clock).items() if k != 'radius_m'}):
        response = client.post('/admin/sessions', json={'title': 'Valid', 'gps': gps}, **credentials)
        assert response.status_code == 201, response.text
        assert response.json()['gps']['radius_m'] == gps.get('radius_m', 100)


@pytest.mark.parametrize('radius,accuracy,offset,distance', [
    (25, 12.5, -60, 25), (100, 50, 15, 100), (1000, 100, 0, 1000), (100, 0, 0, 0),
])
def test_attendance_inclusive_geofence_and_capture_boundaries(env, radius, accuracy, offset, distance):
    client, _, clock = env
    _, headers, sha = approved_account(client)
    lecture = gps_session(client, clock, radius_m=radius, accuracy_m=0)
    response, _ = submit(client, headers, sha, lecture,
                         {'distance_m': distance, 'accuracy_m': accuracy, 'captured_at': clock[0]+offset})
    assert response.status_code == 201, response.text
    assert response.json()['gps_status'] == 'passed'


@pytest.mark.parametrize('location', [
    None, {}, {'distance_m': -0.001}, {'distance_m': 100.000001},
    {'accuracy_m': -0.001}, {'accuracy_m': 50.001},
    {'age': -60.001}, {'age': 15.001},
])
def test_missing_outside_stale_or_poor_location_fails_and_consumes(env, location):
    client, app, clock = env
    _, headers, sha = approved_account(client)
    lecture = gps_session(client, clock)
    summary = None
    if location is not None:
        summary = {'distance_m': 1, 'accuracy_m': 1, 'captured_at': clock[0]}
        summary.update({k: v for k, v in location.items() if k != 'age'})
        summary['captured_at'] += location.get('age', 0)
    if location == {}:
        challenge = attempt(client, headers, sha, lecture).json()
        body = {**result(challenge, sha), 'location': None}
        response = client.post('/api/attendance', headers=headers, json=body)
    else:
        response, body = submit(client, headers, sha, lecture, summary)
    assert response.status_code == 403, response.text
    assert client.post('/api/attendance', headers=headers, json=body).status_code == 409
    with app.state.db.connect() as conn:
        assert conn.execute('SELECT COUNT(*) FROM attendance').fetchone()[0] == 0


@pytest.mark.parametrize('enabled', [True, False])
def test_raw_coordinates_malformed_and_nonfinite_rejected_without_consuming(env, enabled, caplog):
    client, _, clock = env
    _, headers, sha = approved_account(client)
    lecture = gps_session(client, clock) if enabled else session(client)
    challenge = attempt(client, headers, sha, lecture).json()
    body = result(challenge, sha)
    valid = {'distance_m': 10, 'accuracy_m': 5, 'captured_at': clock[0]}
    coordinates = {'latitude': 35.7123456789, 'longitude': 51.4987654321}
    bad_bodies = [{**body, 'location': {**valid, **coordinates}}, {**body, **coordinates},
                  {**body, 'metrics': {**body['metrics'], **coordinates}}]
    for location in ({}, [], 'bad', {**valid, 'distance_m': '1'}, {**valid, 'accuracy_m': True}):
        bad_bodies.append({**body, 'location': location})
    for key in valid:
        for value in (float('nan'), float('inf'), -float('inf')):
            bad_bodies.append({**body, 'location': {**valid, key: value}})
    for bad_body in bad_bodies:
        response = client.post('/api/attendance', content=json.dumps(bad_body),
                               headers={**headers, 'Content-Type': 'application/json'})
        assert response.status_code == 422, response.text
        assert '35.7123456789' not in response.text and '51.4987654321' not in response.text
    assert '35.7123456789' not in caplog.text and '51.4987654321' not in caplog.text
    body['location'] = valid
    response = client.post('/api/attendance', headers=headers, json=body)
    assert response.status_code == 201, response.text


def test_disable_is_immediate_hides_center_and_preserves_pins_and_attempt(env):
    client, app, clock = env
    _, headers, sha = approved_account(client)
    lecture = gps_session(client, clock)
    challenge = attempt(client, headers, sha, lecture).json()
    endpoint = f'/admin/sessions/{lecture["id"]}/gps/disable'
    with app.state.db.connect() as conn:
        initial = dict(conn.execute('SELECT * FROM sessions WHERE id=?', (lecture['id'],)).fetchone())
        initial_attempt = dict(conn.execute('SELECT * FROM attempts WHERE id=?', (challenge['attempt_id'],)).fetchone())
    dashboard = client.get('/admin', auth=('admin', ADMIN_PASSWORD)).text
    assert 'GPS on · 100 m radius' in dashboard and endpoint in dashboard
    assert 'name="csrf_token"' in dashboard
    assert str(lecture['gps']['latitude']) not in dashboard
    assert client.post(endpoint).status_code == 401
    assert client.post(endpoint, auth=('admin', ADMIN_PASSWORD)).status_code == 403
    credentials = admin(client)
    assert client.post(endpoint, **credentials).json() == {'id': lecture['id'], 'gps': {'enabled': False}}
    clock[0] += 1
    assert client.post(endpoint, **credentials).status_code == 200
    for path, kwargs in (('/api/sessions', {'headers': headers}),
                         (f'/api/sessions/{lecture["id"]}', {'headers': headers}),
                         ('/admin/sessions', {'auth': ('admin', ADMIN_PASSWORD)})):
        response = client.get(path, **kwargs).json()
        item = response[0] if isinstance(response, list) else response
        assert item['gps'] == {'enabled': False}
        assert 'latitude' not in json.dumps(item) and 'gps_json' not in item
    with app.state.db.connect() as conn:
        updated = dict(conn.execute('SELECT * FROM sessions WHERE id=?', (lecture['id'],)).fetchone())
        assert updated.pop('gps_disabled_at') == clock[0]-1
        initial.pop('gps_disabled_at')
        assert updated == initial
        assert dict(conn.execute('SELECT * FROM attempts WHERE id=?', (challenge['attempt_id'],)).fetchone()) == initial_attempt
    # Even a stale/invalid measurement left in a mobile payload is dropped after disable.
    body = result(challenge, sha)
    body['location'] = {'distance_m': -1, 'accuracy_m': 9999, 'captured_at': clock[0]-900}
    response = client.post('/api/attendance', headers=headers, json=body)
    assert response.status_code == 201, response.text
    assert response.json()['gps_status'] == 'disabled' and 'location' not in response.json()
    with app.state.db.connect() as conn:
        assert json.loads(conn.execute('SELECT gps_json FROM attendance').fetchone()[0]) == {'status': 'disabled'}
    history = client.get('/api/attendance', headers=headers).json()[0]
    assert history['gps_status'] == 'disabled' and 'location' not in history
    csv_text = client.get(f'/admin/sessions/{lecture["id"]}/results.csv', auth=('admin', ADMIN_PASSWORD)).text
    csv_row = list(csv.DictReader(io.StringIO(csv_text)))[0]
    assert csv_row['gps_status'] == 'disabled' and csv_row['gps_distance_m'] == csv_row['gps_accuracy_m'] == ''
    dashboard = client.get('/admin', auth=('admin', ADMIN_PASSWORD)).text
    assert 'GPS off' in dashboard and endpoint not in dashboard
    assert client.post(f'/admin/sessions/{lecture["id"]}/gps/enable', **credentials).status_code == 404
    assert client.patch(f'/admin/sessions/{lecture["id"]}', json={'gps': policy(clock)}, **credentials).status_code == 404


def test_disabled_defaults_html_disable_and_expiry(env):
    client, _, clock = env
    _, headers = account(client)
    lecture = session(client)
    assert lecture['gps'] == {'enabled': False}
    credentials = admin(client)
    for gps in (None, {'enabled': False}):
        body = {'title': 'Legacy'}
        if gps is not None:
            body['gps'] = gps
        response = client.post('/admin/sessions', json=body, **credentials)
        assert response.status_code == 201 and response.json()['gps'] == {'enabled': False}
    lecture = gps_session(client, clock)
    endpoint = f'/admin/sessions/{lecture["id"]}/gps/disable'
    response = client.post(endpoint, auth=credentials['auth'],
                           data={'csrf_token': credentials['headers']['X-CSRF-Token']}, follow_redirects=False)
    assert response.status_code == 303 and response.headers['location'] == '/admin'
    assert client.post('/admin/sessions/unknown/gps/disable', **credentials).status_code == 404
    assert client.get('/api/sessions/unknown', headers=headers).status_code == 404
    clock[0] += 300
    assert client.post(endpoint, **credentials).status_code == 410
    assert client.get(f'/api/sessions/{lecture["id"]}', headers=headers).status_code == 410
    assert client.get('/api/sessions', headers=headers).json() == []


def test_pre_gps_database_migrates_preserving_users_sessions_results(tmp_path, monkeypatch):
    path = tmp_path / 'classsweep.sqlite3'
    with sqlite3.connect(path) as conn:
        conn.executescript('''
CREATE TABLE users (id TEXT PRIMARY KEY,username TEXT NOT NULL COLLATE NOCASE UNIQUE,display_name TEXT NOT NULL,password_hash TEXT NOT NULL,device_id TEXT NOT NULL,created_at REAL NOT NULL);
CREATE TABLE classroom_refs (id TEXT PRIMARY KEY,payload TEXT NOT NULL,created_at REAL NOT NULL);
CREATE TABLE sessions (id TEXT PRIMARY KEY,title TEXT NOT NULL,code_a TEXT UNIQUE NOT NULL,code_b TEXT UNIQUE NOT NULL,created_at REAL NOT NULL,expires_at REAL NOT NULL,classroom_reference_id TEXT NOT NULL REFERENCES classroom_refs(id));
CREATE TABLE attempts (id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),session_id TEXT NOT NULL REFERENCES sessions(id),device_id TEXT NOT NULL,reference_sha256 TEXT NOT NULL,direction TEXT NOT NULL,expires_at REAL NOT NULL,consumed_at REAL,created_at REAL NOT NULL);
CREATE TABLE attendance (id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),session_id TEXT NOT NULL REFERENCES sessions(id),attempt_id TEXT UNIQUE NOT NULL REFERENCES attempts(id),device_id TEXT NOT NULL,reference_sha256 TEXT NOT NULL,classroom_reference_id TEXT NOT NULL REFERENCES classroom_refs(id),direction TEXT NOT NULL,checks TEXT NOT NULL,metrics TEXT NOT NULL,recorded_at REAL NOT NULL,UNIQUE(user_id,session_id));
''')
        conn.execute('INSERT INTO users VALUES (?,?,?,?,?,?)', ('old-user', 'legacy', 'Legacy', password_hash(PASSWORD), DEVICE, 1))
        conn.execute('INSERT INTO classroom_refs VALUES (?,?,?)', ('old-room', '{"id":"old-room","name":"Old room","views":[]}', 1))
        conn.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?,?)', ('old-session', 'Old lecture', '1234', '5678', 1, 1800000300, 'old-room'))
        conn.execute('INSERT INTO attempts VALUES (?,?,?,?,?,?,?,?,?)', ('old-attempt', 'old-user', 'old-session', DEVICE, 'a'*64, 'left', 1800000090, 2, 1))
        conn.execute('INSERT INTO attendance VALUES (?,?,?,?,?,?,?,?,?,?,?)', ('old-result', 'old-user', 'old-session', 'old-attempt', DEVICE, 'a'*64, 'old-room', 'left', '{}', '{}', 2))
        old_user = conn.execute('SELECT * FROM users').fetchone()
        old_session = conn.execute('SELECT * FROM sessions').fetchone()
        old_attendance = conn.execute('SELECT * FROM attendance').fetchone()
    monkeypatch.setenv('CLASSSWEEP_DATA_DIR', str(tmp_path))
    monkeypatch.setenv('CLASSSWEEP_ADMIN_PASSWORD', ADMIN_PASSWORD)
    app = create_app()
    app.state.now = lambda: 1800000000
    Database(path)  # Repeat migration is harmless.
    with app.state.db.connect() as conn:
        assert tuple(conn.execute('SELECT * FROM users').fetchone()) == old_user
        assert tuple(conn.execute('SELECT * FROM sessions').fetchone())[:7] == old_session
        assert tuple(conn.execute('SELECT * FROM attendance').fetchone())[:11] == old_attendance
    with TestClient(app) as client:
        logged_in = client.post('/api/login', json={'username': 'legacy', 'password': PASSWORD, 'device_id': DEVICE})
        assert logged_in.status_code == 200, logged_in.text
        headers = {'Authorization': 'Bearer '+logged_in.json()['token']}
        active = client.get('/api/sessions', headers=headers).json()[0]
        assert active['id'] == 'old-session' and active['gps'] == {'enabled': False}
        history = client.get('/api/attendance', headers=headers).json()[0]
        assert history['id'] == 'old-result' and history['gps_status'] == 'disabled'
        # Explicit column inserts work against migrated tables for sessions AND attendance.
        _, fresh_headers, sha = approved_account(client, username='fresh')
        lecture = gps_session(client, [1800000000])
        response, _ = submit(client, fresh_headers, sha, lecture,
                             {'distance_m': 100, 'accuracy_m': 50, 'captured_at': 1800000000})
        assert response.status_code == 201, response.text
