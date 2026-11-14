"""Protocol/lifecycle tests: supplied local claims are not a vision implementation."""
import copy
import hashlib
import io
import json
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from classsweep.app import create_app, MAX_IMAGE

PASSWORD = "student-password-for-tests"
ADMIN_PASSWORD = "admin-password-for-tests"
DEVICE = "test-phone-device"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("CLASSSWEEP_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("CLASSSWEEP_ADMIN_PASSWORD", ADMIN_PASSWORD)
    app = create_app()
    clock = [1_800_000_000.0]
    app.state.now = lambda: clock[0]
    with TestClient(app) as client:
        yield client, app, clock


def admin(client):
    auth = ("admin", ADMIN_PASSWORD)
    token = client.get("/admin/csrf", auth=auth)
    assert token.status_code == 200
    return {"auth": auth, "headers": {"X-CSRF-Token": token.json()["csrf_token"]}}


def account(client, username="student", device=DEVICE):
    response = client.post("/api/register", json={"username": username, "password": PASSWORD,
                                                "display_name": "Student Example", "device_id": device})
    assert response.status_code == 201, response.text
    payload = response.json()
    return payload, {"Authorization": f'Bearer {payload["token"]}'}


def png():
    output = io.BytesIO()
    Image.new("RGB", (32, 24), (20, 60, 100)).save(output, "PNG")
    return output.getvalue()


def upload(client, headers, raw=None, mime="image/png", device=DEVICE):
    return client.post("/api/enrollment", headers=headers, data={"device_id": device},
                       files={"image": ("reference.png", png() if raw is None else raw, mime)})


def approved_account(client, username="student", device=DEVICE):
    user, headers = account(client, username, device)
    enrolled = upload(client, headers, device=device)
    assert enrolled.status_code == 201, enrolled.text
    response = client.post(f'/admin/enrollments/{user["user"]["id"]}/approve', **admin(client))
    assert response.status_code == 200, response.text
    return user, headers, enrolled.json()["reference_sha256"]


def room_payload(name="Room 101"):
    return {"name": name, "views": [{"id": "front", "width": 640, "height": 480,
            "keypoints": [[10.0 + i, 20.0 + i] for i in range(8)],
            "descriptors": [[(i + j) % 256 for j in range(32)] for i in range(8)]}]}


def room(client):
    response = client.post("/api/admin/classroom", json=room_payload(), **admin(client))
    assert response.status_code == 201, response.text
    return response.json()


def session(client, ttl=300):
    room(client)
    response = client.post("/admin/sessions", json={"title": "Lecture 1", "ttl_seconds": ttl}, **admin(client))
    assert response.status_code == 201, response.text
    return response.json()


def attempt(client, headers, sha, lecture, device=DEVICE, reverse=False):
    codes = [lecture["code_a"], lecture["code_b"]]
    if reverse:
        codes.reverse()
    return client.post("/api/attempts", headers=headers, json={"session_id": lecture["id"], "code_a": codes[0],
                       "code_b": codes[1], "device_id": device, "reference_sha256": sha})


def result(challenge, sha, device=DEVICE):
    return {"attempt_id": challenge["attempt_id"], "device_id": device, "reference_sha256": sha,
            "classroom_reference_id": challenge["classroom_reference_id"], "direction": challenge["direction"],
            "checks": {key: True for key in ["face_match", "single_face", "turn_completed", "returned_to_center",
                "continuous_face", "liveness_passed", "room_match", "rear_camera_scan", "rear_camera_recheck", "motion_correlated"]},
            "metrics": {"match_distance": 0.35, "max_yaw_degrees": 24.0, "return_yaw_degrees": 2.0,
                "duration_ms": 3200.0, "room_good_matches": 24, "room_inlier_ratio": 0.8,
                "room_recheck_good_matches": 22, "room_recheck_inlier_ratio": 0.75, "motion_correlation": 0.9}}


def test_full_lifecycle_exact_reference_purge_and_csv(env):
    client, app, _ = env
    user, headers, sha = approved_account(client)
    uid = user["user"]["id"]
    reference = client.get("/api/enrollment/reference", headers=headers)
    assert reference.content == png()
    assert hashlib.sha256(reference.content).hexdigest() == sha == reference.headers["X-Reference-SHA256"]
    assert reference.headers["X-Device-ID"] == DEVICE
    assert reference.headers["cache-control"] == "no-store"
    assert upload(client, headers).status_code == 409
    assert client.post(f"/admin/enrollments/{uid}/delete", **admin(client)).status_code == 409
    assert client.post("/api/enrollment/template-ready", headers=headers,
                       json={"device_id": DEVICE, "reference_sha256": sha}).status_code == 200
    lecture = session(client)
    assert len(lecture["code_a"]) == len(lecture["code_b"]) == 4
    active = client.get("/api/sessions", headers=headers).json()
    assert active[0]["id"] == lecture["id"] and "code_a" not in active[0]
    challenge = attempt(client, headers, sha, lecture, reverse=True)
    assert challenge.status_code == 201, challenge.text
    challenge = challenge.json()
    assert challenge["direction"] in ("left", "right")
    assert "return to center" in challenge["instruction"]
    # Image purge preserves enrollment and an already-issued attempt.
    assert client.post(f"/admin/enrollments/{uid}/delete", **admin(client)).status_code == 200
    assert client.get("/api/enrollment/reference", headers=headers).status_code == 410
    me = client.get("/api/me", headers=headers).json()
    assert me["enrollment_status"] == "approved" and me["reference_sha256"] == sha
    assert me["template_ready"] is True and me["image_available"] is False
    submitted = client.post("/api/attendance", headers=headers, json=result(challenge, sha))
    assert submitted.status_code == 201, submitted.text
    assert len(client.get("/api/attendance", headers=headers).json()) == 1
    assert client.post("/api/attendance", headers=headers, json=result(challenge, sha)).status_code == 409
    assert attempt(client, headers, sha, lecture).status_code == 409
    exported = client.get(f'/admin/sessions/{lecture["id"]}/results.csv', auth=("admin", ADMIN_PASSWORD))
    assert exported.status_code == 200 and "student" in exported.text and sha in exported.text
    assert client.get("/admin", auth=("admin", ADMIN_PASSWORD)).status_code == 200
    with app.state.db.connect() as conn:
        stored = conn.execute("SELECT * FROM users").fetchone()
        assert stored["password_hash"] != PASSWORD and stored["password_hash"].startswith("scrypt$")
        assert conn.execute("SELECT token_hash FROM tokens").fetchone()[0] != user["token"]
        assert conn.execute("SELECT image FROM enrollments").fetchone()[0] is None


def test_login_tokens_and_fail_closed(env, monkeypatch):
    client, app, clock = env
    user, headers = account(client)
    body = {"username": "student", "password": PASSWORD, "device_id": DEVICE}
    assert client.post("/api/login", json={**body, "password": "wrong"}).status_code == 401
    assert client.post("/api/login", json={**body, "device_id": "another-phone"}).status_code == 403
    logged_in = client.post("/api/login", json=body)
    assert logged_in.status_code == 200 and logged_in.json()["token"] != user["token"]
    assert client.post("/api/logout", headers=headers).status_code == 204
    assert client.get("/api/me", headers=headers).status_code == 401
    second = {"Authorization": f'Bearer {logged_in.json()["token"]}'}
    clock[0] += 7 * 86400
    assert client.get("/api/me", headers=second).status_code == 401
    assert client.get("/api/me").status_code == 401
    assert client.get("/admin").status_code == 401
    assert client.get("/admin", auth=("admin", "bad")).status_code == 401
    monkeypatch.delenv("CLASSSWEEP_ADMIN_PASSWORD")
    with pytest.raises(RuntimeError, match="ADMIN_PASSWORD"):
        create_app()


def test_pending_rejection_retry_and_decode_validation(env):
    client, _, _ = env
    user, headers = account(client)
    uid = user["user"]["id"]
    assert upload(client, headers, raw=b"not an image").status_code == 422
    assert upload(client, headers, mime="image/jpeg").status_code == 415
    assert upload(client, headers, mime="application/octet-stream").status_code == 415
    assert upload(client, headers, raw=b"x" * (MAX_IMAGE + 1)).status_code == 413
    assert upload(client, headers, device="wrong-device").status_code == 403
    assert upload(client, headers).status_code == 201
    assert client.get("/api/enrollment/reference", headers=headers).status_code == 403
    assert upload(client, headers).status_code == 409
    assert client.post(f"/admin/enrollments/{uid}/approve", auth=("admin", ADMIN_PASSWORD)).status_code == 403
    assert client.post(f"/admin/enrollments/{uid}/reject", **admin(client)).status_code == 200
    assert client.get(f"/admin/enrollments/{uid}/image", auth=("admin", ADMIN_PASSWORD)).status_code == 404
    assert upload(client, headers).status_code == 201


def test_attempt_owner_binding_expiry_and_replay(env):
    client, _, clock = env
    _, headers, sha = approved_account(client)
    lecture = session(client)
    _, other, other_sha = approved_account(client, 'other_student', 'other-device')
    first = attempt(client, headers, sha, lecture).json()
    assert client.post('/api/attendance', headers=other, json=result(first, other_sha, 'other-device')).status_code == 404
    wrong = result(first, sha)
    wrong['device_id'] = 'wrong-device'
    assert client.post('/api/attendance', headers=headers, json=wrong).status_code == 403
    assert client.post('/api/attendance', headers=headers, json=result(first, sha)).status_code == 409
    superseded = attempt(client, headers, sha, lecture).json()
    active = attempt(client, headers, sha, lecture).json()
    assert client.post('/api/attendance', headers=headers, json=result(superseded, sha)).status_code == 409
    clock[0] += 91
    assert client.post('/api/attendance', headers=headers, json=result(active, sha)).status_code == 410
    clock[0] += 300
    assert attempt(client, headers, sha, lecture).status_code == 410


@pytest.mark.parametrize('field', ['direction', 'reference_sha256', 'classroom_reference_id'])
def test_binding_mismatch_consumes_attempt(env, field):
    client, _, _ = env
    _, headers, sha = approved_account(client)
    challenge = attempt(client, headers, sha, session(client)).json()
    body = result(challenge, sha)
    body[field] = ('right' if challenge['direction'] == 'left' else 'left') if field == 'direction' else '0' * 64
    assert client.post('/api/attendance', headers=headers, json=body).status_code == 403
    assert client.post('/api/attendance', headers=headers, json=result(challenge, sha)).status_code == 409


def test_failed_checks_rejected_and_unknown_image_fields_disallowed(env):
    client, _, _ = env
    _, headers, sha = approved_account(client)
    lecture = session(client)
    challenge = attempt(client, headers, sha, lecture).json()
    body = result(challenge, sha)
    body['image'] = 'routine-camera-image-must-not-be-accepted'
    assert client.post('/api/attendance', headers=headers, json=body).status_code == 422
    body = result(challenge, sha)
    body['checks']['face_match'] = 'true'
    assert client.post('/api/attendance', headers=headers, json=body).status_code == 422
    body['checks']['face_match'] = False
    assert client.post('/api/attendance', headers=headers, json=body).status_code == 403
    assert client.get('/api/attendance', headers=headers).json() == []


def test_duplicate_submission_is_atomic(env):
    client, _, _ = env
    _, headers, sha = approved_account(client)
    challenge = attempt(client, headers, sha, session(client)).json()
    body = result(challenge, sha)
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: client.post('/api/attendance', headers=headers, json=body).status_code, range(2)))
    assert sorted(responses) == [201, 409]
    assert len(client.get('/api/attendance', headers=headers).json()) == 1


def test_room_version_pinning_and_invalid_descriptors(env):
    client, _, _ = env
    _, headers, sha = approved_account(client)
    lecture = session(client)
    original = lecture['classroom_reference_id']
    newer = room(client)
    assert newer['id'] != original
    assert client.get('/api/classroom', headers=headers).json()['id'] == newer['id']
    assert client.get('/api/classroom', params={'reference_id': original}, headers=headers).json()['id'] == original
    assert attempt(client, headers, sha, lecture).json()['classroom_reference_id'] == original
    bad = room_payload()
    bad['views'][0]['descriptors'][0][0] = 256
    assert client.post('/api/admin/classroom', json=bad, **admin(client)).status_code == 422
    assert client.post('/admin/sessions', json={'title': 'No CSRF'}, auth=('admin', ADMIN_PASSWORD)).status_code == 403


def test_admin_html_forms_and_enrollment_revocation(env):
    client, _, _ = env
    user, headers, sha = approved_account(client)
    lecture = session(client)
    challenge = attempt(client, headers, sha, lecture).json()
    credentials = admin(client)
    response = client.post(f'/admin/enrollments/{user["user"]["id"]}/revoke',
                           data={'csrf_token': credentials['headers']['X-CSRF-Token']},
                           auth=credentials['auth'], follow_redirects=False)
    assert response.status_code == 303
    assert client.post('/api/attendance', headers=headers, json=result(challenge, sha)).status_code == 409
    assert client.get('/api/me', headers=headers).json()['enrollment_status'] == 'rejected'
    assert client.get('/api/enrollment/reference', headers=headers).status_code == 403
