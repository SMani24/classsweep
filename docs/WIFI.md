# Wi-Fi connection

The phone and laptop communicate over the local network. A USB cable is not required during enrollment or attendance. Internet access is not required for normal use once the app and its bundled models are installed.

## On this laptop

```bash
python3 /home/smani24/Documents/Codex/2026-11-13/classsweep/scripts/run_server.py
```

Keep this terminal open and the laptop awake. The launcher selects Wi-Fi before Ethernet, ignores VPN/container interfaces, and shows:

- `Phone server URL: http://laptop.local:8000` when Avahi confirms the alias.
- `IP fallback: http://<current-laptop-IP>:8000`.
- The instructor dashboard URL.

The alias is published only while this server launcher is running. The laptop's OS hostname is not changed. Restart the server after moving to another network or receiving a different IP address. Use `--hostname classsweep.local` if another device already owns `laptop.local`; enter that same name in the app.

The laptop already has Avahi available. On another Ubuntu/Debian machine, install `avahi-daemon` and `avahi-utils` and enable the Avahi service. If Avahi is missing, the server still works at the printed IP. No `/etc/hosts` entry on the laptop is needed; that would not configure the phone's DNS.

## On the phone

1. Connect to the same ordinary Wi-Fi network as the laptop. Avoid guest Wi-Fi initially.
2. Install the updated `/home/smani24/apks/ClassSweep-debug.apk` over the existing app. Do not uninstall or clear its storage.
3. In the phone browser, open `http://laptop.local:8000/health`. A working connection returns `{"status":"ok","service":"classsweep",...}`.
4. In the app, open **Connection & privacy**, enter `http://laptop.local:8000`, and tap **Test connection**. A successful probe checks the ClassSweep service without uploading a photo or account token.
5. Tap **Save server**, then sign in to the same account. The random device ID is retained. Fresh installations default to this local hostname; previously saved addresses remain unchanged until you edit them.

Changing the server URL signs you out. Face templates are scoped to the exact server URL, account, device and approved-image hash. After moving from localhost/IP to the hostname, prepare the approved face reference again before the instructor purges its image. If the image was already purged, switch back to the previously used address when available or ask for re-enrollment approval. Choose one stable URL before enrolling for the presentation.

## Tablet hotspot rehearsal

Join the tablet hotspot from the laptop and both phones before starting ClassSweep. Keep the tablet powered and the laptop awake. On each phone, try the laptop's printed numeric address in the browser with `/health` before testing the app. If the numeric address works while the hostname fails intermittently, use the numeric address for that demo. Restart the launcher if the laptop receives a new IP. Make the address choice before enrollment template preparation, since changing it changes the local reference scope.

When troubleshooting, record the time and whether the problem is on both phones, the URL being used, and the outcome of the browser health check. On the laptop, keep the Uvicorn terminal available to see the corresponding HTTP request. The laptop health endpoint can be responsive during a phone-side Wi-Fi interruption. See the [engineering handoff](ENGINEERING_HANDOFF.md#tablet-hotspot-investigation-and-presentation-runbook) for the observed tests and failure branches.

## If it does not connect

- **Hostname fails but numeric IP works:** use the printed IP address in both the browser and app. Android's updated DNS resolver supports `.local`, but older phones/resolver versions and some networks do not. Changing the laptop's hosts file will not fix the phone.
- **Both fail:** confirm the server is running, both devices share a LAN, and port 8000 is not blocked. Guest networks may isolate devices even when their Wi-Fi names look the same. A VPN may intercept local traffic; use its local-network bypass setting if available.
- **Different network:** a `.local` name works only on the local link; it is not an internet domain. Rejoin the same network or create a small private test LAN that permits connected devices to communicate.
- **Firewall:** allow inbound TCP 8000 on the laptop's Wi-Fi interface from your LAN; multicast DNS also needs UDP 5353. Do not disable the firewall globally. The project does not change firewall rules automatically.
- **Port already in use:** stop the old ClassSweep server, or choose `--port 8001` and include `:8001` in the phone's URL.
- **Wrong laptop interface:** the launcher prints its selection. Override it with `--interface <Wi-Fi-or-Ethernet-interface>`.

## Optional USB mode

USB is a fallback, not a requirement:

```bash
python3 scripts/run_server.py --local-only
adb reverse tcp:8000 tcp:8000
```

Then use `http://127.0.0.1:8000` on the phone. A phone's localhost address otherwise refers to the phone itself.

## Privacy

The current prototype uses HTTP for local demonstrations. It does not encrypt enrollment photos, passwords or attendance traffic. Use your own test data on a trusted network, and use HTTPS before collecting real student data on a shared network. Local processing and the one-time reviewed enrollment exception remain unchanged.

Reference: [Android DNS resolver and multicast .local support](https://source.android.com/docs/core/ota/modular-system/dns-resolver).
