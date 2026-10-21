"""Pairing a phone with Compii over the local network, securely.

- Core normally listens only on this PC (127.0.0.1). A second, encrypted
  listener on the local network starts only when a phone is being paired or
  is already paired.
- The listener uses a self-signed certificate made once for this PC. Its
  fingerprint travels inside the pairing QR code, so the phone can be sure
  it is talking to this PC and nobody on the Wi-Fi can read or fake traffic.
- Pairing codes are single-use, expire after 5 minutes and allow 5 wrong
  tries. Each phone gets its own key; only a hash of it is stored, and any
  phone can be removed at any time.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import ipaddress
import json
import secrets
import socket
import threading
import time
import urllib.parse
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

CODE_SECONDS = 300
CODE_TRIES = 5
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L


def lan_ip() -> str:
    """This PC's address on the local network (no traffic is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def _is_overlay(ip: str) -> bool:
    """Tailscale and similar mesh VPNs hand out 100.64.0.0/10 addresses that work from anywhere."""
    import ipaddress

    try:
        return ipaddress.ip_address(ip) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


_reach_cache: tuple[float, list[str]] = (0.0, [])


def reach_addresses() -> list[str]:
    """Every address a paired phone can try, best first: home Wi-Fi, then mesh-VPN addresses
    (Tailscale, ZeroTier, …) that reach this PC from anywhere, then any the user added
    in COMPII_REMOTE_HOSTS (a DNS name, say)."""
    global _reach_cache
    if time.time() - _reach_cache[0] < 60 and _reach_cache[1]:
        return list(_reach_cache[1])
    import os
    import subprocess

    found: list[str] = []
    try:
        found += [i[4][0] for i in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
    except OSError:
        pass
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=3,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        found += out.stdout.split()
    except (OSError, subprocess.SubprocessError):
        pass  # Tailscale isn't installed
    lan = lan_ip()
    overlay = [ip for ip in found if _is_overlay(ip)]
    extra = [h.strip() for h in os.environ.get("COMPII_REMOTE_HOSTS", "").split(",") if h.strip()]
    out_list: list[str] = []
    for h in [lan, *overlay, *extra]:
        if h and h != "127.0.0.1" and h not in out_list:
            out_list.append(h)
    _reach_cache = (time.time(), out_list or [lan])
    return list(_reach_cache[1])


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass
class Device:
    name: str
    token_hash: str
    id: str = field(default_factory=lambda: "d" + uuid.uuid4().hex[:8])
    paired_at: float = field(default_factory=time.time)
    last_seen: float | None = None


class Pairing:
    """Devices, pairing codes and the certificate for this PC."""

    def __init__(self, folder: Path) -> None:
        self.folder = folder
        folder.mkdir(parents=True, exist_ok=True)
        self.devices_path = folder / "devices.json"
        self._lock = threading.Lock()
        self.devices: dict[str, Device] = {}
        self._code: str | None = None
        self._code_expires = 0.0
        self._tries = 0
        self._load()

    # ---- devices ------------------------------------------------------------

    def _load(self) -> None:
        if self.devices_path.exists():
            try:
                for d in json.loads(self.devices_path.read_text(encoding="utf-8-sig")):
                    self.devices[d["id"]] = Device(**d)
            except ValueError:
                self.devices_path.replace(self.devices_path.with_suffix(f".broken-{int(time.time())}.json"))

    def _save(self) -> None:
        tmp = self.devices_path.with_suffix(".tmp")
        tmp.write_text(json.dumps([asdict(d) for d in self.devices.values()], indent=1), encoding="utf-8")
        tmp.replace(self.devices_path)

    def device_for(self, token: str) -> Device | None:
        if not token:
            return None
        h = _hash(token)
        with self._lock:
            for d in self.devices.values():
                if secrets.compare_digest(d.token_hash, h):
                    if not d.last_seen or time.time() - d.last_seen > 30:
                        d.last_seen = time.time()
                        self._save()
                    return d
        return None

    def remove(self, device_id: str) -> bool:
        with self._lock:
            if self.devices.pop(device_id, None) is None:
                return False
            self._save()
            return True

    def view(self) -> list[dict[str, Any]]:
        return [{k: v for k, v in asdict(d).items() if k != "token_hash"} for d in self.devices.values()]

    # ---- pairing codes -------------------------------------------------------------

    def new_code(self) -> tuple[str, float]:
        with self._lock:
            raw = "".join(secrets.choice(_ALPHABET) for _ in range(8))
            self._code = f"{raw[:4]}-{raw[4:]}"
            self._code_expires = time.time() + CODE_SECONDS
            self._tries = 0
            return self._code, self._code_expires

    def claim(self, code: str, name: str) -> tuple[Device, str]:
        """Swap a valid pairing code for a new device key (shown to the phone once)."""
        with self._lock:
            if self._code is None or time.time() > self._code_expires:
                raise PermissionError("That pairing code has expired. Start pairing again on your PC.")
            if self._tries >= CODE_TRIES:
                self._code = None
                raise PermissionError("Too many wrong codes. Start pairing again on your PC.")
            given = code.strip().upper().replace(" ", "")
            if not secrets.compare_digest(given.replace("-", ""), self._code.replace("-", "")):
                self._tries += 1
                raise PermissionError("That code doesn't match the one on your PC.")
            self._code = None  # single use
            token = secrets.token_urlsafe(32)
            device = Device(name.strip()[:60] or "Phone", _hash(token))
            self.devices[device.id] = device
            self._save()
            return device, token

    # ---- certificate -------------------------------------------------------------------

    @property
    def cert_path(self) -> Path:
        return self.folder / "remote-cert.pem"

    @property
    def key_path(self) -> Path:
        return self.folder / "remote-key.pem"

    def ensure_certificate(self) -> str:
        """Create this PC's certificate once; returns its SHA-256 fingerprint (hex)."""
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID

        if not (self.cert_path.exists() and self.key_path.exists()):
            key = ec.generate_private_key(ec.SECP256R1())
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Compii on {socket.gethostname()}")])
            now = dt.datetime.now(dt.timezone.utc)
            cert = (
                x509.CertificateBuilder()
                .subject_name(name).issuer_name(name)
                .public_key(key.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(days=1))
                .not_valid_after(now + dt.timedelta(days=3650))
                .add_extension(x509.SubjectAlternativeName([
                    x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                ]), critical=False)
                .sign(key, hashes.SHA256())
            )
            self.key_path.write_bytes(key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            self.cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        return self.fingerprint()

    def fingerprint(self) -> str:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes

        cert = x509.load_pem_x509_certificate(self.cert_path.read_bytes())
        return cert.fingerprint(hashes.SHA256()).hex()


def pairing_link(host: str, port: int, code: str, fingerprint: str, pc: str, also: list[str] | None = None) -> str:
    q = {"h": host, "p": port, "c": code, "f": fingerprint, "n": pc}
    if also:
        q["a"] = ",".join(also)  # more addresses to try, e.g. Tailscale for when you're out
    return f"compii://pair?{urllib.parse.urlencode(q)}"


class RemoteHost:
    """The encrypted local-network listener; started only when needed."""

    def __init__(self, app, pairing: Pairing, port: int) -> None:
        self.app = app
        self.pairing = pairing
        self.port = port
        self._server = None
        self._task: asyncio.Task | None = None
        self.error: str | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self) -> None:
        if self.running:
            return
        import uvicorn

        self.pairing.ensure_certificate()
        config = uvicorn.Config(
            self.app, host="0.0.0.0", port=self.port, lifespan="off", log_level="warning",
            ssl_certfile=str(self.pairing.cert_path), ssl_keyfile=str(self.pairing.key_path),
        )
        self._server = uvicorn.Server(config)
        self._server.install_signal_handlers = lambda: None  # the local server owns Ctrl+C
        self._task = asyncio.create_task(self._server.serve())
        await asyncio.sleep(0.3)
        if self._task.done():
            exc = self._task.exception()
            self.error = f"Couldn't open port {self.port} for phones: {exc}" if exc else "Phone listener stopped."
            raise RuntimeError(self.error)
        self.error = None

    async def stop(self) -> None:
        if self._server is not None:
            self._server.should_exit = True
        if self._task is not None:
            try:
                await asyncio.wait_for(self._task, 5)
            except Exception:  # noqa: BLE001
                pass
        self._task = None
