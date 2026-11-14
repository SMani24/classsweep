import hashlib
import hmac
import secrets
import sqlite3
from contextlib import contextmanager

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
 id TEXT PRIMARY KEY, username TEXT NOT NULL COLLATE NOCASE UNIQUE,
 display_name TEXT NOT NULL, password_hash TEXT NOT NULL, device_id TEXT NOT NULL,
 created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
 token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS enrollments (
 user_id TEXT PRIMARY KEY REFERENCES users(id), status TEXT NOT NULL,
 image BLOB, mime TEXT, sha256 TEXT, device_id TEXT NOT NULL, updated_at REAL NOT NULL,
 approved_at REAL, provisioned_at REAL
);
CREATE TABLE IF NOT EXISTS classroom_refs (
 id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, code_a TEXT UNIQUE NOT NULL,
 code_b TEXT UNIQUE NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL,
 classroom_reference_id TEXT NOT NULL REFERENCES classroom_refs(id)
);
CREATE TABLE IF NOT EXISTS attempts (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
 session_id TEXT NOT NULL REFERENCES sessions(id), device_id TEXT NOT NULL,
 reference_sha256 TEXT NOT NULL, direction TEXT NOT NULL, expires_at REAL NOT NULL,
 consumed_at REAL, created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS attempts_user_session ON attempts(user_id,session_id);
CREATE TABLE IF NOT EXISTS attendance (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
 session_id TEXT NOT NULL REFERENCES sessions(id), attempt_id TEXT UNIQUE NOT NULL REFERENCES attempts(id),
 device_id TEXT NOT NULL, reference_sha256 TEXT NOT NULL,
 classroom_reference_id TEXT NOT NULL REFERENCES classroom_refs(id),
 direction TEXT NOT NULL, checks TEXT NOT NULL, metrics TEXT NOT NULL, recorded_at REAL NOT NULL,
 UNIQUE(user_id,session_id)
);
CREATE TABLE IF NOT EXISTS csrf_tokens (token_hash TEXT PRIMARY KEY, expires_at REAL NOT NULL);
"""


class Database:
    def __init__(self, path):
        self.path = str(path)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript(SCHEMA)

    @contextmanager
    def connect(self, write=False):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            if write:
                db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def password_hash(password):
    salt = secrets.token_bytes(16)
    key = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=16384, r=8, p=1)
    return f"scrypt${salt.hex()}${key.hex()}"


def verify_password(password, encoded):
    try:
        kind, salt, expected = encoded.split("$")
        if kind != "scrypt":
            return False
        actual = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1)
        return hmac.compare_digest(actual.hex(), expected)
    except (ValueError, TypeError):
        return False
