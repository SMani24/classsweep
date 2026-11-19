#!/usr/bin/env python3
"""Start ClassSweep on Wi-Fi with a temporary laptop.local alias."""
import argparse
import os
from pathlib import Path
import secrets
import signal
import subprocess

from lan import LocalAlias, local_hostname, select_lan_address

ROOT = Path(__file__).resolve().parents[1]


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument('--lan', action='store_true', help='Wi-Fi/LAN mode (the default; retained for compatibility)')
    mode.add_argument('--local-only', action='store_true', help='Listen only on localhost for optional USB forwarding')
    result.add_argument('--port', type=int, default=8000)
    result.add_argument('--hostname', type=local_hostname, default='laptop.local', help='Temporary .local alias (default: laptop.local)')
    result.add_argument('--interface', help='Select a Wi-Fi/Ethernet interface when several are active')
    result.add_argument('--no-mdns', action='store_true', help='Use IP addresses without advertising a local alias')
    return result


def main():
    args = parser().parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit('Port must be between 1 and 65535.')
    python = ROOT / '.venv/bin/python'
    if not python.exists():
        raise SystemExit('Run scripts/setup_server.sh first.')
    try:
        interface, address = (None, '127.0.0.1') if args.local_only else select_lan_address(args.interface)
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
    data = Path(os.environ.get('CLASSSWEEP_DATA_DIR', ROOT / 'data')).resolve()
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    password_file = data / 'admin-password.txt'
    environment = os.environ.copy()
    if not environment.get('CLASSSWEEP_ADMIN_PASSWORD'):
        if not password_file.exists():
            descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                output.write(secrets.token_urlsafe(24) + '\n')
        environment['CLASSSWEEP_ADMIN_PASSWORD'] = password_file.read_text().strip()
        print(f'Administrator username: admin; password is in {password_file}', flush=True)
    environment['CLASSSWEEP_DATA_DIR'] = str(data)
    alias = None
    server = None
    previous_handlers = {}

    def forward(signum, _frame):
        if server is not None and server.poll() is None:
            server.send_signal(signum)
        else:
            raise KeyboardInterrupt

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, forward)
        if not args.local_only:
            print(f'Wi-Fi/LAN interface: {interface}', flush=True)
            if not args.no_mdns:
                alias = LocalAlias(args.hostname, address)
                if alias.start():
                    print(f'Phone server URL: http://{args.hostname}:{args.port}', flush=True)
            print(f'IP fallback: http://{address}:{args.port}', flush=True)
            print('Keep phone and laptop on the same Wi-Fi. No USB cable is needed.', flush=True)
            print('Restart the server after changing Wi-Fi networks or the laptop IP address.', flush=True)
            print('Local HTTP is unencrypted; use a trusted network for this prototype.', flush=True)
        print(f'Dashboard: http://{address}:{args.port}/admin', flush=True)
        # Bind to the chosen LAN address, avoiding unrelated VPN/container interfaces.
        server = subprocess.Popen([str(python), '-m', 'uvicorn', 'classsweep.app:create_app', '--factory',
                                   '--host', address, '--port', str(args.port)], cwd=ROOT / 'server', env=environment)
        code = server.wait()
        return code if code >= 0 else 128 - code
    except KeyboardInterrupt:
        return 130
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if alias is not None:
            alias.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == '__main__':
    raise SystemExit(main())
