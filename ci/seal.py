"""Encrypt CI artifacts that show the owner's real data before they are published.
AES-256-GCM, key = HKDF-SHA256(APP_KEY, salt "sahm", info "ci-artifact-v1"), AAD "sahm-ci";
<file>.enc = b"SAHMENC1" + nonce(12) + ciphertext||tag. The plaintext file is deleted."""
import os
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"sahm", info=b"ci-artifact-v1").derive(os.environ["APP_KEY"].encode())
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    nonce = os.urandom(12)
    with open(path + ".enc", "wb") as f:
        f.write(b"SAHMENC1" + nonce + AESGCM(key).encrypt(nonce, data, b"sahm-ci"))
    os.remove(path)
    print("sealed", path)
