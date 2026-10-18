"""API keys in Windows Credential Manager, write-only.

Keys are never written to Compii's files, never logged and never sent back to
the app: the app can only set, replace or remove a key, and ask whether one
is stored.
"""

from __future__ import annotations

import sys

PREFIX = "Compii/"


class KeyStoreError(Exception):
    pass


class KeyStore:
    """Generic credentials in the Windows Credential Manager."""

    def __init__(self, prefix: str = PREFIX) -> None:
        self.prefix = prefix

    def _api(self):
        if sys.platform != "win32":
            raise KeyStoreError("Storing keys needs Windows Credential Manager.")
        import ctypes
        from ctypes import wintypes

        class CREDENTIAL(ctypes.Structure):
            _fields_ = [
                ("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME),
                ("CredentialBlobSize", wintypes.DWORD), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD), ("Attributes", ctypes.c_void_p),
                ("TargetAlias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR),
            ]

        adv = ctypes.WinDLL("advapi32", use_last_error=True)
        adv.CredWriteW.argtypes = [ctypes.POINTER(CREDENTIAL), wintypes.DWORD]
        adv.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.POINTER(CREDENTIAL))]
        adv.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
        adv.CredFree.argtypes = [ctypes.c_void_p]
        return ctypes, CREDENTIAL, adv

    def set(self, name: str, value: str) -> None:
        if not value.strip():
            raise KeyStoreError("The key is empty.")
        ctypes, CREDENTIAL, adv = self._api()
        blob = value.strip().encode("utf-16-le")
        buf = (ctypes.c_ubyte * len(blob)).from_buffer_copy(blob)
        cred = CREDENTIAL()
        cred.Type = 1  # CRED_TYPE_GENERIC
        cred.TargetName = self.prefix + name
        cred.CredentialBlobSize = len(blob)
        cred.CredentialBlob = ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte))
        cred.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE: this user, this PC
        cred.UserName = "compii"
        if not adv.CredWriteW(ctypes.byref(cred), 0):
            raise KeyStoreError(f"Windows didn't save the key (error {ctypes.get_last_error()}).")

    def get(self, name: str) -> str | None:
        """For Core's own use when calling a provider. Never exposed over the API."""
        try:
            ctypes, CREDENTIAL, adv = self._api()
        except KeyStoreError:
            return None
        p = ctypes.POINTER(CREDENTIAL)()
        if not adv.CredReadW(self.prefix + name, 1, 0, ctypes.byref(p)):
            return None
        try:
            c = p.contents
            return bytes(c.CredentialBlob[: c.CredentialBlobSize]).decode("utf-16-le")
        finally:
            adv.CredFree(p)

    def has(self, name: str) -> bool:
        return self.get(name) is not None

    def delete(self, name: str) -> bool:
        try:
            ctypes, _, adv = self._api()
        except KeyStoreError:
            return False
        return bool(adv.CredDeleteW(self.prefix + name, 1, 0))


class MemoryKeyStore(KeyStore):
    """For tests only."""

    def __init__(self) -> None:
        super().__init__()
        self._d: dict[str, str] = {}

    def set(self, name: str, value: str) -> None:
        if not value.strip():
            raise KeyStoreError("The key is empty.")
        self._d[name] = value.strip()

    def get(self, name: str) -> str | None:
        return self._d.get(name)

    def delete(self, name: str) -> bool:
        return self._d.pop(name, None) is not None
