"""Local server. Phone evidence is client-attested, never server-side vision."""
import csv
import hashlib
import hmac
import html
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
    app = FastAPI(title="ClassSweep", version="0.1.0")
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

    def now():
        return app.state.now()

    def admin(credentials: HTTPBasicCredentials | None = Depends(basic)):
        if (credentials is None or not hmac.compare_digest(credentials.username.encode(), b"admin")
                or not hmac.compare_digest(digest(credentials.password), digest(admin_password))):
            raise HTTPException(401, "Admin authentication required", headers={"WWW-Authenticate": 'Basic realm="ClassSweep admin"'})
        return True

    async def admin_write(request: Request, authenticated=Depends(admin)):
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
        return {"status": "ok"}

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

    @app.post("/api/logout", status_code=204)
    def logout(user=Depends(current_user), credentials=Depends(bearer)):
        with db.connect(write=True) as conn:
            conn.execute("DELETE FROM tokens WHERE token_hash=?", (digest(credentials.credentials),))
        return Response(status_code=204)

    @app.get("/api/me")
    def me(user=Depends(current_user)):
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
            return [dict(row) for row in conn.execute("SELECT id,title,expires_at,classroom_reference_id FROM sessions WHERE expires_at>? ORDER BY created_at DESC", (now(),))]

    @app.post("/api/attempts", status_code=201)
    def attempt(body: AttemptCreate, user=Depends(current_user)):
        with db.connect(write=True) as conn:
            approved(conn, user, body.device_id, body.reference_sha256)
            session = conn.execute("SELECT * FROM sessions WHERE id=? AND ((code_a=? AND code_b=?) OR (code_a=? AND code_b=?))", (body.session_id, body.code_a, body.code_b, body.code_b, body.code_a)).fetchone()
            if session is None:
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
            row = conn.execute("SELECT a.*,s.expires_at AS session_expires,s.classroom_reference_id FROM attempts a JOIN sessions s ON s.id=a.session_id WHERE a.id=? AND a.user_id=?", (body.attempt_id, user["id"])).fetchone()
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
                if not error:
                    result = {"id": secrets.token_urlsafe(18), "session_id": row["session_id"], "recorded_at": now()}
                    try:
                        conn.execute("INSERT INTO attendance VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                                     (result["id"], user["id"], row["session_id"], row["id"], body.device_id,
                                      body.reference_sha256, body.classroom_reference_id, body.direction,
                                      body.checks.model_dump_json(), body.metrics.model_dump_json(), result["recorded_at"]))
                    except sqlite3.IntegrityError:
                        error = (409, "Attendance already recorded")
        if error:
            raise HTTPException(*error)
        return result

    @app.get("/api/attendance")
    def own_attendance(user=Depends(current_user)):
        with db.connect() as conn:
            return [dict(row) for row in conn.execute("SELECT a.id,a.session_id,s.title,a.recorded_at FROM attendance a JOIN sessions s ON s.id=a.session_id WHERE a.user_id=? ORDER BY a.recorded_at DESC", (user["id"],))]

    @app.get("/admin/csrf", dependencies=[Depends(admin)])
    def get_csrf():
        return {"csrf_token": csrf_token()}

    def create_session(body):
        with db.connect(write=True) as conn:
            room = conn.execute("SELECT value FROM settings WHERE key='classroom'").fetchone()
            if room is None:
                raise HTTPException(409, "Calibrate classroom from instructor phone first")
            # All live codes distinct even across A/B positions, so board OCR cannot mix sessions.
            used = {r[0] for r in conn.execute("SELECT code_a FROM sessions UNION SELECT code_b FROM sessions")}
            available = [f"{n:04d}" for n in range(1000, 10000) if f"{n:04d}" not in used]
            if len(available) < 2:
                raise HTTPException(409, "Code space exhausted; archive old database before creating more sessions")
            a = secrets.choice(available)
            available.remove(a)
            b = secrets.choice(available)
            result = {"id": secrets.token_urlsafe(18), "title": body.title, "code_a": a, "code_b": b,
                      "expires_at": now() + body.ttl_seconds, "classroom_reference_id": room["value"]}
            conn.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)", (result["id"], body.title, a, b, now(), result["expires_at"], room["value"]))
        return result

    @app.post("/admin/sessions", status_code=201, dependencies=[Depends(admin_write)])
    def session_create(body: SessionCreate):
        return create_session(body)

    @app.post("/admin/sessions/create", dependencies=[Depends(admin_write)])
    async def session_create_html(request: Request):
        form = await request.form()
        try:
            body = SessionCreate(title=form.get("title"), ttl_seconds=int(form.get("ttl_seconds", 300)))
        except (ValidationError, ValueError, TypeError):
            raise HTTPException(422, "Provide a title and TTL between 30 and 1800 seconds")
        create_session(body)
        return RedirectResponse("/admin", status_code=303)

    @app.get("/admin/sessions", dependencies=[Depends(admin)])
    def all_sessions():
        with db.connect() as conn:
            return [dict(row) for row in conn.execute("SELECT * FROM sessions ORDER BY created_at DESC")]

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
            rows = conn.execute("SELECT u.username,u.display_name,a.recorded_at,a.device_id,a.reference_sha256,a.classroom_reference_id,a.direction,a.metrics FROM attendance a JOIN users u ON u.id=a.user_id WHERE a.session_id=? ORDER BY a.recorded_at", (session_id,)).fetchall()
        output = io.StringIO(newline="")
        writer = csv.writer(output)
        writer.writerow(["username", "display_name", "recorded_at_utc_unix", "device_id", "reference_sha256", "classroom_reference_id", "direction", "metrics_json"])
        for row in rows:
            # Spreadsheet formula injection protection on user-controlled string cells.
            writer.writerow([("'" + v if isinstance(v, str) and v.lstrip().startswith(("=", "+", "-", "@")) else v) for v in row])
        return Response(output.getvalue(), media_type="text/csv", headers={"Content-Disposition": 'attachment; filename="classsweep-results.csv"'})

    @app.get("/", response_class=HTMLResponse)
    def home():
        return '<!doctype html><html lang="en"><title>ClassSweep</title><h1>ClassSweep</h1><p>Local attendance server. <a href="/admin">Instructor dashboard</a></p></html>'

    @app.get("/admin", response_class=HTMLResponse, dependencies=[Depends(admin)])
    def dashboard():
        e = html.escape
        csrf = csrf_token()
        with db.connect() as conn:
            enrollments = conn.execute("SELECT u.id,u.username,u.display_name,e.status,e.sha256,e.image IS NOT NULL AS available,e.provisioned_at FROM users u LEFT JOIN enrollments e ON e.user_id=u.id ORDER BY u.created_at DESC").fetchall()
            sessions = conn.execute("SELECT s.*,(SELECT COUNT(*) FROM attendance a WHERE a.session_id=s.id) AS total FROM sessions s ORDER BY created_at DESC").fetchall()
            room = conn.execute("SELECT c.payload FROM classroom_refs c JOIN settings s ON c.id=s.value WHERE s.key='classroom'").fetchone()
        rows = []
        for row in enrollments:
            uid = e(row["id"], quote=True)
            actions = []
            if row["status"] == "pending":
                actions += [("approve", "Approve"), ("reject", "Reject")]
            if row["status"] == "approved":
                actions.append(("revoke", "Revoke enrollment"))
            if row["available"] and (row["status"] != "approved" or row["provisioned_at"] is not None):
                actions.append(("delete", "Purge image" if row["status"] == "approved" else "Delete image"))
            forms = "".join(f'<form method="post" action="/admin/enrollments/{uid}/{action}"><input type="hidden" name="csrf_token" value="{csrf}"><button>{label}</button></form>' for action, label in actions)
            image = f'<a href="/admin/enrollments/{uid}/image"><img alt="Enrollment reference" src="/admin/enrollments/{uid}/image" width="140"></a>' if row["available"] else "No retained image"
            rows.append(f'<tr><td>{e(row["display_name"])}<br>{e(row["username"])}</td><td>{e(row["status"] or "none")}<br><small>{e(row["sha256"] or "")}</small></td><td>{image}</td><td>{forms}</td></tr>')
        session_rows = "".join(f'<tr><td>{e(s["title"])}</td><td class="codes">{e(s["code_a"])} &nbsp; {e(s["code_b"])}</td><td>{"Open" if s["expires_at"] > now() else "Expired"}<br>{max(0,int(s["expires_at"]-now()))}s left</td><td>{s["total"]} <a href="/admin/sessions/{e(s["id"])}/results.csv">CSV</a></td></tr>' for s in sessions)
        room_name = e(json.loads(room["payload"])["name"]) if room else "Not calibrated — use instructor phone to upload processed ORB descriptors."
        return f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ClassSweep instructor</title>
<style>body{{font:16px system-ui;max-width:1100px;margin:2rem auto;padding:0 1rem;background:#f5f7fa;color:#172436}}table{{border-collapse:collapse;width:100%;background:white}}td,th{{padding:12px;text-align:left;border-bottom:1px solid #ddd}}small{{overflow-wrap:anywhere}}button,input{{padding:9px;margin:4px}}form{{display:inline-block}}.codes{{font-size:2rem;font-weight:bold;white-space:nowrap}}img{{max-height:160px;object-fit:contain}}</style>
<h1>ClassSweep instructor</h1><p>Room: {room_name}</p><p><a href="/admin">Refresh dashboard</a>. Approval binds the exact image to the registered device. Purge images only after phone template provisioning; revoke separately to remove enrollment.</p>
<h2>Create session</h2><form method="post" action="/admin/sessions/create"><input type="hidden" name="csrf_token" value="{csrf}"><input name="title" required maxlength="150" placeholder="Lecture title"><label>TTL seconds <input name="ttl_seconds" type="number" min="30" max="1800" value="300" required></label><button>Create fresh codes</button></form>
<h2>Sessions</h2><table><tr><th>Title</th><th>Board codes A / B</th><th>Status</th><th>Results</th></tr>{session_rows}</table>
<h2>Enrollment review</h2><table><tr><th>Account</th><th>Status / exact SHA-256</th><th>Reference image</th><th>Actions</th></tr>{''.join(rows)}</table><p>Routine attendance contains local checks and metrics only. These client claims are not independent proof of presence. HTTP Basic credentials remain cached by the browser; close the private browser session when finished.</p></html>'''

    return app
