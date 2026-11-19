"""LAN selection and server launcher lifecycle, independent of a real network."""
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from lan import LocalAlias, lan_candidates, local_hostname, select_lan_address
import run_server


def iface(name, address):
    return {'ifname': name, 'addr_info': [{'family': 'inet', 'scope': 'global', 'local': address}]}


def test_wifi_preferred_over_ethernet_and_virtual_networks():
    assert lan_candidates([
        iface('tun0', '172.18.0.1'), iface('docker0', '172.17.0.1'),
        iface('lo', '127.0.0.1'), iface('enp1s0', '192.168.1.10'),
        iface('wlo1', '192.168.31.122'), iface('wlan9', '169.254.1.2'),
    ]) == [('wlo1', '192.168.31.122'), ('enp1s0', '192.168.1.10')]


def test_local_hostname_validation():
    assert local_hostname('Laptop.local') == 'laptop.local'
    for invalid in ['laptop', 'laptop.example', '-bad.local', 'a.b.local', 'http://laptop.local', 'bad name.local']:
        with pytest.raises(ValueError):
            local_hostname(invalid)


def test_selection_and_absent_network_are_explicit(monkeypatch):
    import lan
    monkeypatch.setattr(lan.subprocess, 'run', lambda *a, **kw: SimpleNamespace(stdout='[{"ifname":"wlan0","addr_info":[{"family":"inet","scope":"global","local":"192.168.1.5"}]}]'))
    assert select_lan_address() == ('wlan0', '192.168.1.5')
    with pytest.raises(RuntimeError, match='No active'):
        select_lan_address('enp1s0')
    monkeypatch.setattr(lan.subprocess, 'run', Mock(side_effect=FileNotFoundError()))
    with pytest.raises(RuntimeError, match='iproute2'):
        select_lan_address()


def test_launcher_modes():
    assert not run_server.parser().parse_args([]).local_only
    assert run_server.parser().parse_args(['--local-only']).local_only
    assert run_server.parser().parse_args(['--hostname', 'classsweep.local']).hostname == 'classsweep.local'
    with pytest.raises(SystemExit):
        run_server.parser().parse_args(['--local-only', '--lan'])


def test_launcher_uses_lan_address_and_cleans_alias_on_server_failure(tmp_path, monkeypatch):
    (tmp_path / '.venv/bin').mkdir(parents=True)
    (tmp_path / '.venv/bin/python').touch()
    monkeypatch.setattr(run_server, 'ROOT', tmp_path)
    monkeypatch.setattr(sys, 'argv', ['run_server.py'])
    monkeypatch.setenv('CLASSSWEEP_ADMIN_PASSWORD', 'test-only-password')
    monkeypatch.delenv('CLASSSWEEP_DATA_DIR', raising=False)
    monkeypatch.setattr(run_server, 'select_lan_address', lambda _: ('wlan0', '192.168.1.5'))
    alias = Mock()
    alias.start.return_value = True
    factory = Mock(return_value=alias)
    monkeypatch.setattr(run_server, 'LocalAlias', factory)
    process = Mock()
    process.wait.return_value = 1
    process.poll.return_value = 1
    launch = Mock(return_value=process)
    monkeypatch.setattr(run_server.subprocess, 'Popen', launch)
    assert run_server.main() == 1
    factory.assert_called_once_with('laptop.local', '192.168.1.5')
    command = launch.call_args.args[0]
    assert command[command.index('--host') + 1] == '192.168.1.5'
    assert 'test-only-password' not in command
    alias.close.assert_called_once()


def test_alias_unavailable_does_not_stop_ip_connection(monkeypatch):
    import lan
    monkeypatch.setattr(lan.shutil, 'which', lambda _: None)
    alias = LocalAlias('laptop.local', '192.168.1.5')
    assert alias.start() is False
    alias.close()
