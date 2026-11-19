"""Linux LAN selection and lifetime-bound Avahi alias publication."""
from __future__ import annotations

import ipaddress
import json
import re
import shutil
import subprocess
import threading


def lan_candidates(interfaces):
    """Prefer physical Wi-Fi/Ethernet; never select a VPN/container address."""
    candidates = []
    for interface in interfaces:
        name = interface.get('ifname', '')
        if not name.startswith(('wl', 'en', 'eth')):
            continue
        for address in interface.get('addr_info', []):
            if address.get('family') != 'inet' or address.get('scope') != 'global':
                continue
            value = ipaddress.ip_address(address['local'])
            if not isinstance(value, ipaddress.IPv4Address) or value.is_loopback or value.is_link_local:
                continue
            candidates.append((name, str(value)))
    return sorted(candidates, key=lambda item: (not item[0].startswith('wl'), item[0], item[1]))


def select_lan_address(interface=None):
    try:
        result = subprocess.run(['ip', '-j', '-4', 'address', 'show', 'up'],
                                capture_output=True, text=True, check=True, timeout=5)
        candidates = lan_candidates(json.loads(result.stdout))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise RuntimeError('Could not read LAN addresses. Check that Linux iproute2 is installed.') from error
    if interface:
        candidates = [item for item in candidates if item[0] == interface]
    if not candidates:
        raise RuntimeError('No active Wi-Fi/Ethernet IPv4 address. Connect to Wi-Fi, or use --local-only for USB testing.')
    return candidates[0]


def local_hostname(value):
    if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.local', value):
        raise ValueError('Use a single local name, such as laptop.local or classsweep.local.')
    return value.lower()


class LocalAlias:
    """Publish an address without changing the OS hostname or DNS configuration."""
    def __init__(self, hostname, address):
        self.hostname = local_hostname(hostname)
        self.address = address
        self.process = None
        self.thread = None
        self.ready = threading.Event()
        self.established = False

    def start(self):
        executable = shutil.which('avahi-publish')
        if not executable:
            print('Local name unavailable: install avahi-utils and run avahi-daemon. Use the printed IP address meanwhile.', flush=True)
            return False
        try:
            self.process = subprocess.Popen([executable, '-a', '-R', self.hostname, self.address],
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except OSError as error:
            print(f'Local name unavailable: {error}. Use the printed IP address.', flush=True)
            return False
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        self.ready.wait(4)
        if not self.established:
            print('Local name is not confirmed. Use the IP address below if it does not resolve.', flush=True)
        return self.established

    def _read(self):
        for line in self.process.stdout:
            line = line.strip()
            if 'Established under name' in line:
                self.established = True
                print(f'Local name ready: {self.hostname}', flush=True)
                self.ready.set()
            elif line:
                print(f'Local name: {line}', flush=True)
        self.ready.set()
        if self.process.poll() not in (None, 0):
            print('Local-name publisher stopped. Use the printed IP address or restart the server.', flush=True)

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            if self.thread:
                self.thread.join(timeout=1)
            self.process.stdout.close()
