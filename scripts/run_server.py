#!/usr/bin/env python3
"""Start the local ClassSweep server without putting credentials in shell history."""
import argparse
import os
from pathlib import Path
import secrets
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lan', action='store_true', help='Listen on the local network instead of localhost')
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    data = Path(os.environ.get('CLASSSWEEP_DATA_DIR', ROOT / 'data')).resolve()
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    password_file = data / 'admin-password.txt'
    if not os.environ.get('CLASSSWEEP_ADMIN_PASSWORD'):
        if not password_file.exists():
            descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                output.write(secrets.token_urlsafe(24) + '\n')
        os.environ['CLASSSWEEP_ADMIN_PASSWORD'] = password_file.read_text().strip()
        print(f'Administrator username: admin; password is in {password_file}', flush=True)
    os.environ['CLASSSWEEP_DATA_DIR'] = str(data)
    python = ROOT / '.venv/bin/python'
    if not python.exists():
        raise SystemExit('Run scripts/setup_server.sh first.')
    host = '0.0.0.0' if args.lan else '127.0.0.1'
    print(f'Dashboard: http://127.0.0.1:{args.port}/admin', flush=True)
    if args.lan:
        print('LAN demonstration mode uses unencrypted HTTP. Use USB or HTTPS for real enrollment data.', flush=True)
    os.chdir(ROOT / 'server')
    os.execv(str(python), [str(python), '-m', 'uvicorn', 'classsweep.app:create_app', '--factory',
                          '--host', host, '--port', str(args.port)])


if __name__ == '__main__':
    main()
