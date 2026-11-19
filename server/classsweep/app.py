"""Local server. Phone evidence is client-attested, never server-side vision."""
import csv
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
import warnings

from fastapi import Depends, FastAPI, HTTPException, Request, UploadFile, File, Form
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials, HTTPBearer, HTTPAuthorizationCredentials
from PIL import Image, UnidentifiedImageError
from pydantic import ValidationError

from .models import Register, Login, SessionCreate, AttemptCreate, AttendanceCreate, ClassroomCreate, TemplateReady
from .dashboard import render_dashboard
from .storage import Database, digest, password_hash, verify_password

MAX_IMAGE = 5 * 1024 * 1024
MAX_PIXELS = 16_000_000
TOKEN_TTL = 7 * 86400
ATTEMPT_TTL = 90
basic = HTTPBasic(auto_error=False)
bearer = HTTPBearer(auto_error=False)


class BodyLimitMiddleware:
    """Bound body size before multipart/JSON parsing, including chunked requests."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        limit = (MAX_IMAGE + 65536 if path == "/api/enrollment" else
                 4 * 1024 * 1024 if path == "/api/admin/classroom" else 65536)
        chunks, size = [], 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > limit:
                return await JSONResponse({"detail": "Request body too large"}, status_code=413)(scope, receive, send)
            chunks.append(chunk)
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": b"".join(chunks), "more_body": False}
            return await receive()

        await self.app(scope, replay, send)


def create_app():
    admin_password = os.environ.get("CLASSSWEEP_ADMIN_PASSWORD", "")
    if not admin_password or not admin_password.strip():
        raise RuntimeError("CLASSSWEEP_ADMIN_PASSWORD must be set; no default admin credential exists")
    data_dir = Path(os.environ.get("CLASSSWEEP_DATA_DIR", "data")).expanduser().resolve()
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = Database(data_dir / "classsweep.sqlite3")
    os.chmod(db.path, 0o600)
    app = FastAPI(title="ClassSweep", version="0.2.0")
    app.state.db = db
    app.state.now = time.time  # injectable clock for expiry tests
    dummy_hash = password_hash(secrets.token_urlsafe(32))

    @app.middleware("http")
    async def private_headers(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        return response

    origins = [s.strip() for s in os.environ.get("CLASSSWEEP_CORS_ORIGINS", "").split(",") if s.strip()]
    if origins:
        app.add_middleware(CORSMiddleware, allow_origins=origins, allow_methods=["GET", "POST"],
                           allow_headers=["Authorization", "Content-Type", "X-CSRF-Token"],
                           expose_headers=["X-Reference-SHA256", "X-Device-ID"])
    app.add_middleware(BodyLimitMiddleware)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, exc):
        # Never echo submitted coordinates or other private input in error bodies.
        return JSONResponse({"detail": "Invalid request fields or values"}, status_code=422)

    def now():
        return app.state.now()

    def fresh_capture(captured_at, timestamp):
        return timestamp - 60 <= captured_at <= timestamp + 15

    def live_gps(session):
        return {"enabled": False} if session["gps_disabled_at"] is not None else json.loads(session["gps_json"])

    def session_codes(conn, session):
        override = conn.execute(
            "SELECT code_a,code_b FROM session_test_codes WHERE session_id=?", (session["id"],)
        ).fetchone()
        source = override if override is not None else session
        return source["code_a"], source["code_b"]

    def public_session(session, conn=None):
        fields = ("id", "title", "expires_at", "classroom_reference_id")
        result = {**{key: session[key] for key in fields}, "gps": live_gps(session)}
        if conn is not None:
            a, b = session_codes(conn, session)
            result.update(code_a=a, code_b=b, created_at=session["created_at"])
        return result

    def gps_result_fields(stored):
        gps = json.loads(stored)
        result = {"gps_status": gps["status"]}
        if gps["status"] == "passed":
            result["location"] = {"distance_m": gps["distance_m"], "accuracy_m": gps["accuracy_m"]}
        return result

    def instructor_token_hash(token):
        return hmac.new(admin_password.encode(), token.encode(), hashlib.sha256).hexdigest()

    def instructor_session(credentials):
        if credentials is None or len(credentials.credentials) > 256:
            return None
        with db.connect() as conn:
            return conn.execute(
                "SELECT * FROM instructor_tokens WHERE token_hash=? AND expires_at>?",
                (instructor_token_hash(credentials.credentials), now()),
            ).fetchone()

    def valid_admin_password(value):
        return hmac.compare_digest(digest(value), digest(admin_password))

    def admin(credentials: HTTPBasicCredentials | None = Depends(basic),
              token: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if token is not None:
            if instructor_session(token) is not None:
                return "bearer"
            raise HTTPException(403, "Instructor sign-in required")
        if (credentials is None or credentials.username != "admin"
                or not valid_admin_password(credentials.password)):
            raise HTTPException(401, "Admin authentication required", headers={"WWW-Authenticate": 'Basic realm="ClassSweep admin"'})
        return "basic"

    async def admin_write(request: Request, authenticated=Depends(admin)):
        # App authorization is explicitly set on each request. Browsers may
        # attach cached Basic credentials automatically, so forms retain CSRF.
        if authenticated == "bearer":
            return
        token = request.headers.get("X-CSRF-Token")
        if not token and request.headers.get("content-type", "").startswith("application/x-www-form-urlencoded"):
            token = (await request.form()).get("csrf_token")
        if not isinstance(token, str) or len(token) > 128:
            raise HTTPException(403, "CSRF token required")
        with db.connect() as conn:
            valid = conn.execute("SELECT 1 FROM csrf_tokens WHERE token_hash=? AND expires_at>?", (digest(token), now())).fetchone()
        if not valid:
            raise HTTPException(403, "Invalid or expired CSRF token")

    def csrf_token():
        token = secrets.token_urlsafe(32)
        with db.connect(write=True) as conn:
            conn.execute("DELETE FROM csrf_tokens WHERE expires_at<=?", (now(),))
            conn.execute("INSERT INTO csrf_tokens VALUES (?,?)", (digest(token), now() + 3600))
        return token

    def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if credentials is None or len(credentials.credentials) > 256:
            raise HTTPException(401, "Bearer token required", headers={"WWW-Authenticate": "Bearer"})
        with db.connect() as conn:
            row = conn.execute("SELECT u.* FROM tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=? AND t.expires_at>?",
                               (digest(credentials.credentials), now())).fetchone()
        if row is None:
            raise HTTPException(401, "Invalid or expired token", headers={"WWW-Authenticate": "Bearer"})
        return row

    def public_user(user, conn):
        enrollment = conn.execute("SELECT status,sha256,image IS NOT NULL AS available,provisioned_at FROM enrollments WHERE user_id=?", (user["id"],)).fetchone()
        approved = enrollment is not None and enrollment["status"] == "approved"
        return {"id": user["id"], "username": user["username"], "display_name": user["display_name"], "device_id": user["device_id"],
                "enrollment_status": enrollment["status"] if enrollment else "none",
                "reference_sha256": enrollment["sha256"] if approved else None,
                "template_ready": bool(approved and enrollment["provisioned_at"]),
                "image_available": bool(enrollment and enrollment["available"])}

    def issue_token(user, conn):
        token = secrets.token_urlsafe(32)
        expires_at = now() + TOKEN_TTL
        conn.execute("DELETE FROM tokens WHERE expires_at<=?", (now(),))
        conn.execute("INSERT INTO tokens VALUES (?,?,?)", (digest(token), user["id"], expires_at))
        return {"user": public_user(user, conn), "token": token, "expires_at": expires_at}

    def approved(conn, user, device_id, reference_sha256=None):
        enrollment = conn.execute("SELECT * FROM enrollments WHERE user_id=?", (user["id"],)).fetchone()
        if (enrollment is None or enrollment["status"] != "approved" or device_id != user["device_id"]
                or device_id != enrollment["device_id"] or
                (reference_sha256 is not None and reference_sha256 != enrollment["sha256"])):
            raise HTTPException(403, "Approved enrollment, matching device and reference required")
        return enrollment

    @app.get("/health")
    def health():
        return {"status": "ok", "service": "classsweep", "version": "0.2.0"}

    @app.post("/api/register", status_code=201)
    def register(body: Register):
        uid = secrets.token_urlsafe(18)
        hashed = password_hash(body.password)
        try:
            with db.connect(write=True) as conn:
                conn.execute("INSERT INTO users VALUES (?,?,?,?,?,?)", (uid, body.username, body.display_name, hashed, body.device_id, now()))
                user = conn.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
                return issue_token(user, conn)
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Username already registered")

    @app.post("/api/login")
    def login(body: Login):
        with db.connect(write=True) as conn:
            user = conn.execute("SELECT * FROM users WHERE username=?", (body.username,)).fetchone()
            if not verify_password(body.password, user["password_hash"] if user else dummy_hash) or user is None:
                raise HTTPException(401, "Invalid credentials")
            if body.device_id != user["device_id"]:
                raise HTTPException(403, "Device does not match registered device")
            return issue_token(user, conn)

    def instructor_profile(device_id):
        return {"id": "instructor", "username": "admin", "display_name": "Instructor",
                "device_id": device_id, "enrollment_status": "none", "role": "instructor"}

    @app.post("/api/instructor/login")
    def instructor_login(body: Login):
        if body.username != "admin" or not valid_admin_password(body.password):
            raise HTTPException(401, "Invalid instructor credentials")
        token = secrets.token_urlsafe(32)
        expires_at = now() + TOKEN_TTL
        with db.connect(write=True) as conn:
            conn.execute("DELETE FROM instructor_tokens WHERE expires_at<=?", (now(),))
            conn.execute("INSERT INTO instructor_tokens VALUES (?,?,?)",
                         (instructor_token_hash(token), body.device_id, expires_at))
        return {"user": instructor_profile(body.device_id), "token": token, "expires_at": expires_at}

    @app.post("/api/logout", status_code=204)
    def logout(credentials=Depends(bearer)):
        if credentials is None or len(credentials.credentials) > 256:
            raise HTTPException(401, "Bearer token required")
        with db.connect(write=True) as conn:
            conn.execute("DELETE FROM tokens WHERE token_hash=?", (digest(credentials.credentials),))
            conn.execute("DELETE FROM instructor_tokens WHERE token_hash=?",
                         (instructor_token_hash(credentials.credentials),))
        return Response(status_code=204)

    @app.get("/api/me")
    def me(credentials=Depends(bearer)):
        instructor = instructor_session(credentials)
        if instructor is not None:
            return instructor_profile(instructor["device_id"])
        user = current_user(credentials)
        with db.connect() as conn:
            return public_user(user, conn)

    @app.post("/api/enrollment", status_code=201)
    async def upload_enrollment(device_id: str = Form(...), image: UploadFile = File(...), user=Depends(current_user)):
        try:
            raw = await image.read(MAX_IMAGE + 1)
        finally:
            await image.close()
        if len(raw) > MAX_IMAGE:
            raise HTTPException(413, "Image exceeds 5 MiB")
        if device_id != user["device_id"]:
            raise HTTPException(403, "Device does not match registered device")
        if image.content_type not in ("image/jpeg", "image/png"):
            raise HTTPException(415, "Only JPEG/PNG images accepted")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(raw)) as decoded:
                    fmt = decoded.format
                    if fmt not in ("JPEG", "PNG") or decoded.width * decoded.height > MAX_PIXELS:
                        raise ValueError("Unsupported image or too many pixels")
                    if getattr(decoded, "n_frames", 1) != 1:
                        raise ValueError("Animated images are not enrollment references")
                    decoded.verify()
                with Image.open(io.BytesIO(raw)) as decoded:
                    decoded.load()
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning):
            raise HTTPException(422, "Invalid or oversized decoded JPEG/PNG image")
        mime = "image/jpeg" if fmt == "JPEG" else "image/png"
        if image.content_type != mime:
            raise HTTPException(415, "Declared MIME does not match actual image format")
        sha = hashlib.sha256(raw).hexdigest()
        with db.connect(write=True) as conn:
            previous = conn.execute("SELECT status FROM enrollments WHERE user_id=?", (user["id"],)).fetchone()
            if previous and previous["status"] in ("pending", "approved"):
                raise HTTPException(409, "Enrollment already pending or approved")
            conn.execute("INSERT INTO enrollments (user_id,status,image,mime,sha256,device_id,updated_at,approved_at,provisioned_at) VALUES (?,?,?,?,?,?,?,NULL,NULL) ON CONFLICT(user_id) DO UPDATE SET status=excluded.status,image=excluded.image,mime=excluded.mime,sha256=excluded.sha256,device_id=excluded.device_id,updated_at=excluded.updated_at,approved_at=NULL,provisioned_at=NULL",
                         (user["id"], "pending", raw, mime, sha, device_id, now()))
        return {"status": "pending", "reference_sha256": sha}

    @app.get("/api/enrollment/reference")
    def reference(user=Depends(current_user)):
        with db.connect() as conn:
            enrollment = approved(conn, user, user["device_id"])
            if enrollment["image"] is None:
                raise HTTPException(410, "Source image purged; use installed local template")
            return Response(enrollment["image"], media_type=enrollment["mime"],
                            headers={"X-Reference-SHA256": enrollment["sha256"], "X-Device-ID": enrollment["device_id"]})

    @app.post("/api/enrollment/template-ready")
    def template_ready(body: TemplateReady, user=Depends(current_user)):
        with db.connect(write=True) as conn:
            approved(conn, user, body.device_id, body.reference_sha256)
            conn.execute("UPDATE enrollments SET provisioned_at=COALESCE(provisioned_at,?) WHERE user_id=?", (now(), user["id"]))
        return {"status": "ready"}

    @app.post("/api/admin/classroom", status_code=201, dependencies=[Depends(admin_write)])
    def upload_classroom(body: ClassroomCreate):
        payload = {"id": secrets.token_urlsafe(18), **body.model_dump(), "created_at": now()}
        with db.connect(write=True) as conn:
            conn.execute("INSERT INTO classroom_refs VALUES (?,?,?)", (payload["id"], json.dumps(payload, allow_nan=False), payload["created_at"]))
            conn.execute("INSERT INTO settings VALUES ('classroom',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload["id"],))
        return payload

    @app.get("/api/classroom")
    def classroom(reference_id: str | None = None, user=Depends(current_user)):
        with db.connect() as conn:
            if reference_id is None:
                current = conn.execute("SELECT value FROM settings WHERE key='classroom'").fetchone()
                reference_id = current["value"] if current else ""
            row = conn.execute("SELECT payload FROM classroom_refs WHERE id=?", (reference_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Classroom reference not configured or unknown")
        return json.loads(row["payload"])

    @app.get("/api/sessions")
    def active_sessions(user=Depends(current_user)):
        with db.connect() as conn:
            return [public_session(row) for row in conn.execute("SELECT * FROM sessions WHERE expires_at>? ORDER BY created_at DESC", (now(),))]

    @app.get("/api/sessions/{session_id}")
    def session_policy(session_id: str, user=Depends(current_user)):
        with db.connect() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
            if row is None:
                raise HTTPException(404, "Session not found")
            if row["expires_at"] <= now():
                raise HTTPException(410, "Session expired")
            return public_session(row)

    @app.post("/api/attempts", status_code=201)
    def attempt(body: AttemptCreate, user=Depends(current_user)):
        with db.connect(write=True) as conn:
            approved(conn, user, body.device_id, body.reference_sha256)
            session = conn.execute("SELECT * FROM sessions WHERE id=?", (body.session_id,)).fetchone()
            if session is None or set(session_codes(conn, session)) != {body.code_a, body.code_b}:
                raise HTTPException(404, "Unknown session codes")
            if session["expires_at"] <= now():
                raise HTTPException(410, "Session expired")
            if conn.execute("SELECT 1 FROM attendance WHERE user_id=? AND session_id=?", (user["id"], session["id"])).fetchone():
                raise HTTPException(409, "Attendance already recorded")
            conn.execute("UPDATE attempts SET consumed_at=? WHERE user_id=? AND session_id=? AND consumed_at IS NULL", (now(), user["id"], session["id"]))
            aid, direction = secrets.token_urlsafe(24), secrets.choice(["left", "right"])
            expires = min(now() + ATTEMPT_TTL, session["expires_at"])
            conn.execute("INSERT INTO attempts VALUES (?,?,?,?,?,?,?,?,?)", (aid, user["id"], session["id"], body.device_id, body.reference_sha256, direction, expires, None, now()))
        return {"attempt_id": aid, "session_id": session["id"], "direction": direction,
                "instruction": f"Turn your head {direction}, then return to center.", "expires_at": expires,
                "classroom_reference_id": session["classroom_reference_id"]}

    @app.post("/api/attendance", status_code=201)
    def attendance(body: AttendanceCreate, user=Depends(current_user)):
        # Return errors after leaving transaction so consumption is committed even on rejected results.
        error = None
        result = None
        with db.connect(write=True) as conn:
            row = conn.execute("SELECT a.*,s.expires_at AS session_expires,s.classroom_reference_id,s.gps_json,s.gps_disabled_at FROM attempts a JOIN sessions s ON s.id=a.session_id WHERE a.id=? AND a.user_id=?", (body.attempt_id, user["id"])).fetchone()
            if row is None:
                raise HTTPException(404, "Unknown attempt")
            if row["consumed_at"] is not None:
                raise HTTPException(409, "Attempt already used or superseded")
            conn.execute("UPDATE attempts SET consumed_at=? WHERE id=?", (now(), row["id"]))
            if row["expires_at"] <= now() or row["session_expires"] <= now():
                error = (410, "Attempt or session expired")
            else:
                try:
                    approved(conn, user, body.device_id, body.reference_sha256)
                except HTTPException as exc:
                    error = (exc.status_code, exc.detail)
                if not error and (body.device_id != row["device_id"] or body.reference_sha256 != row["reference_sha256"]
                                  or body.direction != row["direction"] or body.classroom_reference_id != row["classroom_reference_id"]
                                  or not all(body.checks.model_dump().values())):
                    error = (403, "Challenge, device, reference or local checks did not match")
                gps_result = {"status": "disabled"}
                if not error:
                    policy = live_gps(row)
                    if policy["enabled"]:
                        location = body.location
                        if (location is None or not 0 <= location.distance_m <= policy["radius_m"]
                                or not 0 <= location.accuracy_m <= min(policy["radius_m"] / 2, 100)
                                or not fresh_capture(location.captured_at, now())):
                            error = (403, "Fresh, accurate GPS summary inside session radius required")
                        else:
                            gps_result = {"status": "passed", "distance_m": location.distance_m,
                                          "accuracy_m": location.accuracy_m}
                if not error:
                    gps_json = json.dumps(gps_result, allow_nan=False)
                    result = {"id": secrets.token_urlsafe(18), "session_id": row["session_id"], "recorded_at": now(),
                              **gps_result_fields(gps_json)}
                    try:
                        conn.execute("INSERT INTO attendance (id,user_id,session_id,attempt_id,device_id,reference_sha256,classroom_reference_id,direction,checks,metrics,recorded_at,gps_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                                     (result["id"], user["id"], row["session_id"], row["id"], body.device_id,
                                      body.reference_sha256, body.classroom_reference_id, body.direction,
                                      body.checks.model_dump_json(), body.metrics.model_dump_json(), result["recorded_at"], gps_json))
                    except sqlite3.IntegrityError:
                        error = (409, "Attendance already recorded")
        if error:
            raise HTTPException(*error)
        return result

    @app.get("/api/attendance")
    def own_attendance(user=Depends(current_user)):
        with db.connect() as conn:
            rows = conn.execute("SELECT a.id,a.session_id,s.title,a.recorded_at,a.gps_json FROM attendance a JOIN sessions s ON s.id=a.session_id WHERE a.user_id=? ORDER BY a.recorded_at DESC", (user["id"],)).fetchall()
            return [{**{key: row[key] for key in ("id", "session_id", "title", "recorded_at")},
                     **gps_result_fields(row["gps_json"])} for row in rows]

    @app.get("/admin/csrf", dependencies=[Depends(admin)])
    def get_csrf():
        return {"csrf_token": csrf_token()}

    def create_session(body):
        with db.connect(write=True) as conn:
            if body.gps.enabled and not fresh_capture(body.gps.captured_at, now()):
                raise HTTPException(422, "GPS center capture must be fresh (60s past, 15s future)")
            room = conn.execute("SELECT value FROM settings WHERE key='classroom'").fetchone()
            if room is None:
                raise HTTPException(409, "Calibrate classroom from instructor phone first")
            session_id = secrets.token_urlsafe(18)
            timestamp = now()
            live_sessions = conn.execute("SELECT * FROM sessions WHERE expires_at>?", (timestamp,))
            live_codes = {code for session in live_sessions for code in session_codes(conn, session)}
            if body.code_a is not None:
                a, b = body.code_a, body.code_b
                if {a, b} & live_codes:
                    raise HTTPException(409, "A test code is already in an open session. Close that session first.")
                # Legacy columns are unique across history. Reserve internal keys
                # here and keep the user-selected, reusable codes separately.
                stored_a, stored_b = f"test:{session_id}:a", f"test:{session_id}:b"
            else:
                historical = {row[0] for row in conn.execute(
                    "SELECT code_a FROM sessions UNION SELECT code_b FROM sessions"
                )}
                available = [str(n) for n in range(1000, 10000)
                             if str(n) not in historical and str(n) not in live_codes]
                if len(available) < 2:
                    raise HTTPException(409, "Code space exhausted; archive old database before creating more sessions")
                a = stored_a = secrets.choice(available)
                available.remove(a)
                b = stored_b = secrets.choice(available)
            result = {"id": session_id, "title": body.title, "code_a": a, "code_b": b,
                      "expires_at": timestamp + body.ttl_seconds, "classroom_reference_id": room["value"],
                      "gps": body.gps.model_dump()}
            conn.execute(
                "INSERT INTO sessions (id,title,code_a,code_b,created_at,expires_at,classroom_reference_id,gps_json) VALUES (?,?,?,?,?,?,?,?)",
                (session_id, body.title, stored_a, stored_b, timestamp, result["expires_at"],
                 room["value"], body.gps.model_dump_json()),
            )
            if body.code_a is not None:
                conn.execute("INSERT INTO session_test_codes VALUES (?,?,?)", (session_id, a, b))
        return result

    @app.post("/admin/sessions", status_code=201, dependencies=[Depends(admin_write)])
    def session_create(body: SessionCreate):
        return create_session(body)

    @app.post("/admin/sessions/create", dependencies=[Depends(admin_write)])
    async def session_create_html(request: Request):
        form = await request.form()
        try:
            body = SessionCreate(title=form.get("title"), ttl_seconds=int(form.get("ttl_seconds", 300)),
                                 code_a=str(form.get("code_a", "")).strip() or None,
                                 code_b=str(form.get("code_b", "")).strip() or None)
        except (ValidationError, ValueError, TypeError):
            return render_admin_form_error(
                form, "Enter a title, a duration of 30–1800 seconds, and two distinct four-digit codes if overriding.", 422
            )
        try:
            create_session(body)
        except HTTPException as error:
            return render_admin_form_error(form, error.detail, error.status_code)
        return RedirectResponse("/admin#sessions", status_code=303)

    @app.get("/admin/sessions", dependencies=[Depends(admin)])
    def all_sessions():
        with db.connect() as conn:
            return [public_session(row, conn) for row in conn.execute("SELECT * FROM sessions ORDER BY created_at DESC")]

    @app.post("/admin/sessions/{session_id}/close", dependencies=[Depends(admin_write)])
    def close_session(session_id: str):
        with db.connect(write=True) as conn:
            result = conn.execute("UPDATE sessions SET expires_at=MIN(expires_at,?) WHERE id=?", (now(), session_id))
            if not result.rowcount:
                raise HTTPException(404, "Session not found")
        return RedirectResponse("/admin#sessions", status_code=303)

    @app.post("/admin/sessions/{session_id}/gps/disable", dependencies=[Depends(admin_write)])
    def disable_gps(session_id: str, request: Request):
        with db.connect(write=True) as conn:
            session = conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
            if session is None:
                raise HTTPException(404, "Session not found")
            if session["expires_at"] <= now():
                raise HTTPException(410, "Session expired")
            conn.execute("UPDATE sessions SET gps_disabled_at=COALESCE(gps_disabled_at,?) WHERE id=?", (now(), session_id))
        if request.headers.get("content-type", "").startswith("application/x-www-form-urlencoded"):
            return RedirectResponse("/admin", status_code=303)
        return {"id": session_id, "gps": {"enabled": False}}

    @app.get("/admin/enrollments/{user_id}/image", dependencies=[Depends(admin)])
    def admin_image(user_id: str):
        with db.connect() as conn:
            row = conn.execute("SELECT image,mime FROM enrollments WHERE user_id=?", (user_id,)).fetchone()
        if row is None or row["image"] is None:
            raise HTTPException(404, "Image not available")
        return Response(row["image"], media_type=row["mime"])

    @app.post("/admin/enrollments/{user_id}/{action}", dependencies=[Depends(admin_write)])
    def review(user_id: str, action: str, request: Request):
        if action not in ("approve", "reject", "delete", "revoke"):
            raise HTTPException(404, "Unknown action")
        with db.connect(write=True) as conn:
            row = conn.execute("SELECT * FROM enrollments WHERE user_id=?", (user_id,)).fetchone()
            if row is None:
                raise HTTPException(404, "Enrollment not found")
            if action in ("approve", "reject") and row["status"] != "pending":
                raise HTTPException(409, "Only pending enrollments can be approved/rejected")
            if action == "approve":
                if row["image"] is None or hashlib.sha256(row["image"]).hexdigest() != row["sha256"]:
                    raise HTTPException(409, "Image integrity mismatch")
                conn.execute("UPDATE enrollments SET status='approved',approved_at=?,updated_at=? WHERE user_id=?", (now(), now(), user_id))
            elif action == "delete" and row["status"] == "approved":
                if row["provisioned_at"] is None:
                    raise HTTPException(409, "Phone must acknowledge installed template before image purge")
                conn.execute("UPDATE enrollments SET image=NULL,mime=NULL,updated_at=? WHERE user_id=?", (now(), user_id))
            else:
                conn.execute("UPDATE attempts SET consumed_at=? WHERE user_id=? AND consumed_at IS NULL", (now(), user_id))
                if action == "delete":
                    conn.execute("DELETE FROM enrollments WHERE user_id=?", (user_id,))
                else:
                    conn.execute("UPDATE enrollments SET status='rejected',image=NULL,mime=NULL,sha256=NULL,approved_at=NULL,provisioned_at=NULL,updated_at=? WHERE user_id=?", (now(), user_id))
        if request.headers.get("content-type", "").startswith("application/x-www-form-urlencoded"):
            return RedirectResponse("/admin", status_code=303)
        return {"status": "ok", "action": action}

    @app.get("/admin/sessions/{session_id}/results.csv", dependencies=[Depends(admin)])
    def results_csv(session_id: str):
        with db.connect() as conn:
            if not conn.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone():
                raise HTTPException(404, "Session not found")
            rows = conn.execute("SELECT u.username,u.display_name,a.recorded_at,a.device_id,a.reference_sha256,a.classroom_reference_id,a.direction,a.metrics,a.gps_json FROM attendance a JOIN users u ON u.id=a.user_id WHERE a.session_id=? ORDER BY a.recorded_at", (session_id,)).fetchall()
        output = io.StringIO(newline="")
        writer = csv.writer(output)
        writer.writerow(["username", "display_name", "recorded_at_utc_unix", "device_id", "reference_sha256", "classroom_reference_id", "direction", "metrics_json", "gps_status", "gps_distance_m", "gps_accuracy_m"])
        for row in rows:
            gps = json.loads(row["gps_json"])
            values = list(row)[:-1] + [gps["status"], gps.get("distance_m", ""), gps.get("accuracy_m", "")]
            # Spreadsheet formula injection protection on user-controlled string cells.
            writer.writerow([("'" + v if isinstance(v, str) and v.lstrip().startswith(("=", "+", "-", "@")) else v) for v in values])
        return Response(output.getvalue(), media_type="text/csv", headers={"Content-Disposition": 'attachment; filename="classsweep-results.csv"'})

    @app.get("/", response_class=HTMLResponse)
    def home():
        return '<!doctype html><html lang="en"><title>ClassSweep</title><h1>ClassSweep</h1><p>Local attendance server. <a href="/admin">Instructor dashboard</a></p></html>'

    def render_admin_form_error(form, message, status):
        fields = {key: str(form.get(key, ""))[:150] for key in ("title", "ttl_seconds", "code_a", "code_b")}
        return HTMLResponse(dashboard_html(form=fields, form_error=message), status_code=status)

    def dashboard_html(form=None, form_error=None):
        csrf = csrf_token()
        with db.connect() as conn:
            enrollments = conn.execute("SELECT u.id,u.username,u.display_name,e.status,e.image IS NOT NULL AS available,e.provisioned_at FROM users u JOIN enrollments e ON u.id=e.user_id ORDER BY (e.status='pending') DESC,e.updated_at DESC").fetchall()
            sessions = [dict(row, codes=session_codes(conn, row), gps=live_gps(row)) for row in conn.execute(
                "SELECT s.*,(SELECT COUNT(*) FROM attendance a WHERE a.session_id=s.id) AS total FROM sessions s ORDER BY s.created_at DESC")]
            room = conn.execute("SELECT c.payload FROM classroom_refs c JOIN settings s ON c.id=s.value WHERE s.key='classroom'").fetchone()
        return render_dashboard(
            room=json.loads(room["payload"])["name"] if room else None,
            enrollments=enrollments, sessions=sessions, csrf=csrf, timestamp=now(),
            form=form, form_error=form_error,
        )

    @app.get("/admin", response_class=HTMLResponse, dependencies=[Depends(admin)])
    def dashboard():
        return dashboard_html()

    return app
