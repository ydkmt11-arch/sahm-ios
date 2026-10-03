"""Make the owner's personal copy of the app: add Payload/<App>.app/pair.json (pairing key + optional address
hint) to the IPA. Every original entry is copied byte for byte with its ZipInfo, so Unix permissions survive
(the executable keeps +x). Used by the PC server (app/appipa.py) and by CI. Stdlib only.

    PAIR_KEY=... [PAIR_HINT=https://...] python3 personalize.py in.ipa out.ipa
"""
from __future__ import annotations

import io
import json
import os
import re
import sys
import zipfile

KEY_RE = re.compile(r"[A-Za-z0-9_-]{16,128}")


def app_root(names: list[str]) -> str:
    for name in names:
        m = re.match(r"^(Payload/[^/]+\.app/)Info\.plist$", name)
        if m:
            return m.group(1)
    raise ValueError("not an IPA: no Payload/<App>.app/Info.plist")


def personalize(ipa: bytes, key: str, hint: str | None = None) -> bytes:
    if not KEY_RE.fullmatch(key or ""):
        raise ValueError("invalid pairing key")
    if hint is not None and not str(hint).startswith("https://"):
        raise ValueError("the address hint must be an https URL")
    src = zipfile.ZipFile(io.BytesIO(ipa))
    root = app_root(src.namelist())
    target = root + "pair.json"
    doc: dict = {"v": 1, "k": key}
    if hint:
        doc["u"] = hint
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            if info.filename == target:          # personalizing twice replaces the old file
                continue
            dst.writestr(info, src.read(info.filename))
        zi = zipfile.ZipInfo(target, date_time=src.getinfo(root + "Info.plist").date_time)
        zi.create_system = 3                       # Unix: the permission bits below are honoured
        zi.external_attr = 0o100644 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        dst.writestr(zi, json.dumps(doc, separators=(",", ":")).encode())
    return out.getvalue()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    data = personalize(open(sys.argv[1], "rb").read(), os.environ.get("PAIR_KEY", ""), os.environ.get("PAIR_HINT") or None)
    with open(sys.argv[2], "wb") as f:
        f.write(data)
    print(f"personalized {sys.argv[1]} -> {sys.argv[2]} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
