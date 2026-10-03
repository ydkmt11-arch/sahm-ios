"""Make the owner's personal copy of the app and the signed interface bundle it runs. Stdlib only.

personalize(): adds Payload/<App>.app/pair.json (pairing key + optional address hint) and, optionally, the interface
bundle as Payload/<App>.app/www/ (+ www/manifest.json). Every original entry is copied byte for byte with its ZipInfo,
so Unix permissions survive (the executable keeps +x). Used by the PC server (app/appipa.py) and by CI.

build_manifest(): the interface bundle's manifest, shared with the PC server (/api/ui/manifest) and checked by the app
(Sahm/WebBundle.swift):
    {"v": 1, "version": sha256(lines), "built_at": "YYYY-MM-DDTHH:MM:SSZ", "files": [{"p", "h", "n"}...], "sig"}
    lines     = "<path> <sha256> <size>" per file, sorted by path, joined by "\\n"
    canonical = version + "\\n" + built_at + "\\n" + lines      sig = hex(HMAC-SHA256(pair key, canonical))

    PAIR_KEY=... [PAIR_HINT=https://...] [WWW_DIR=dir WWW_BUILT_AT=...] python3 personalize.py in.ipa out.ipa
"""
from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path

KEY_RE = re.compile(r"[A-Za-z0-9_-]{16,128}")
PATH_RE = re.compile(r"[A-Za-z0-9._/-]{1,199}")
STAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


def safe_path(p: str) -> bool:
    return bool(PATH_RE.fullmatch(p)) and not p.startswith("/") and ".." not in p and "//" not in p


def build_manifest(files: dict[str, bytes], built_at: str, key: str) -> dict:
    if not KEY_RE.fullmatch(key or ""):
        raise ValueError("invalid pairing key")
    if not STAMP_RE.fullmatch(built_at or ""):
        raise ValueError("built_at must be YYYY-MM-DDTHH:MM:SSZ")
    if "index.html" not in files:
        raise ValueError("the bundle needs index.html")
    entries = []
    for p in sorted(files):
        if not safe_path(p):
            raise ValueError(f"unsafe path in bundle: {p!r}")
        entries.append({"p": p, "h": hashlib.sha256(files[p]).hexdigest(), "n": len(files[p])})
    lines = "\n".join(f'{e["p"]} {e["h"]} {e["n"]}' for e in entries)
    version = hashlib.sha256(lines.encode()).hexdigest()
    canonical = f"{version}\n{built_at}\n{lines}"
    sig = hmac.new(key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return {"v": 1, "version": version, "built_at": built_at, "files": entries, "sig": sig}


def verify_manifest(man: dict, key: str) -> bool:
    lines = "\n".join(f'{e["p"]} {e["h"]} {e["n"]}' for e in man["files"])
    canonical = f'{man["version"]}\n{man["built_at"]}\n{lines}'
    want = hmac.new(key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(want, man.get("sig", "")) and hashlib.sha256(lines.encode()).hexdigest() == man["version"]


def read_dir(path: str | Path) -> dict[str, bytes]:
    root = Path(path)
    return {f.relative_to(root).as_posix(): f.read_bytes() for f in sorted(root.rglob("*")) if f.is_file()}


def app_root(names: list[str]) -> str:
    for name in names:
        m = re.match(r"^(Payload/[^/]+\.app/)Info\.plist$", name)
        if m:
            return m.group(1)
    raise ValueError("not an IPA: no Payload/<App>.app/Info.plist")


def _add(dst: zipfile.ZipFile, name: str, data: bytes, date_time) -> None:
    zi = zipfile.ZipInfo(name, date_time=date_time)
    zi.create_system = 3                       # Unix: the permission bits below are honoured
    zi.external_attr = 0o100644 << 16
    zi.compress_type = zipfile.ZIP_DEFLATED
    dst.writestr(zi, data)


def personalize(ipa: bytes, key: str, hint: str | None = None,
                www: tuple[dict, dict[str, bytes]] | None = None) -> bytes:
    """www = (manifest, {path: bytes}) from build_manifest(); its files must match the manifest's hashes."""
    if not KEY_RE.fullmatch(key or ""):
        raise ValueError("invalid pairing key")
    if hint is not None and not str(hint).startswith("https://"):
        raise ValueError("the address hint must be an https URL")
    if www is not None:
        man, files = www
        for e in man["files"]:
            if not safe_path(e["p"]) or hashlib.sha256(files[e["p"]]).hexdigest() != e["h"]:
                raise ValueError(f"bundle file does not match its manifest: {e['p']}")
    src = zipfile.ZipFile(io.BytesIO(ipa))
    root = app_root(src.namelist())
    doc: dict = {"v": 1, "k": key}
    if hint:
        doc["u"] = hint
    stamp = src.getinfo(root + "Info.plist").date_time
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            name = info.filename
            if name == root + "pair.json" or (www is not None and name.startswith(root + "www/")):
                continue                           # personalizing twice replaces the old files
            dst.writestr(info, src.read(name))
        _add(dst, root + "pair.json", json.dumps(doc, separators=(",", ":")).encode(), stamp)
        if www is not None:
            man, files = www
            for e in man["files"]:
                _add(dst, root + "www/" + e["p"], files[e["p"]], stamp)
            _add(dst, root + "www/manifest.json", json.dumps(man, separators=(",", ":")).encode(), stamp)
    return out.getvalue()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    key = os.environ.get("PAIR_KEY", "")
    www = None
    if os.environ.get("WWW_DIR"):
        files = read_dir(os.environ["WWW_DIR"])
        www = (build_manifest(files, os.environ.get("WWW_BUILT_AT", "2000-01-01T00:00:00Z"), key), files)
    data = personalize(open(sys.argv[1], "rb").read(), key, os.environ.get("PAIR_HINT") or None, www)
    with open(sys.argv[2], "wb") as f:
        f.write(data)
    extra = f", interface {www[0]['version'][:12]} ({len(www[1])} files)" if www else ""
    print(f"personalized {sys.argv[1]} -> {sys.argv[2]} ({len(data)} bytes{extra})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
