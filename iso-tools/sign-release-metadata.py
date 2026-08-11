#!/usr/bin/env python3
"""Create detached RSA/SHA-256 signatures after checking the application key."""

from __future__ import annotations

import argparse
import base64
import os
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PUBLIC_KEY = REPOSITORY_ROOT / "Scripts/config/Libertix.CatalogPublicKey.xml"


def load_application_public_numbers(path: Path) -> rsa.RSAPublicNumbers:
    root = ET.fromstring(path.read_text(encoding="utf-8"))
    modulus = root.findtext("Modulus")
    exponent = root.findtext("Exponent")
    if not modulus or not exponent:
        raise ValueError("application RSA public key is incomplete")
    return rsa.RSAPublicNumbers(
        int.from_bytes(base64.b64decode(exponent, validate=True), "big"),
        int.from_bytes(base64.b64decode(modulus, validate=True), "big"),
    )


def load_private_key(path: Path) -> rsa.RSAPrivateKey:
    key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError("metadata signing key must be an RSA private key")
    return key


def sign_files(private_key_path: Path, public_key_path: Path, manifests: list[Path]) -> None:
    private_key = load_private_key(private_key_path)
    if private_key.public_key().public_numbers() != load_application_public_numbers(
        public_key_path
    ):
        raise ValueError("private key does not match the RSA public key embedded in Libertix")

    for manifest in manifests:
        payload = manifest.read_bytes()
        if not payload:
            raise ValueError(f"metadata file is empty: {manifest}")
        signature = private_key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
        private_key.public_key().verify(signature, payload, padding.PKCS1v15(), hashes.SHA256())
        encoded = base64.b64encode(signature) + b"\n"
        signature_path = Path(str(manifest) + ".sig")
        signature_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{signature_path.name}.", suffix=".tmp", dir=signature_path.parent
        )
        try:
            with os.fdopen(descriptor, "wb") as temporary:
                temporary.write(encoded)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary_name, signature_path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, default=DEFAULT_PUBLIC_KEY)
    parser.add_argument("manifests", nargs="+", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sign_files(args.private_key, args.public_key, args.manifests)


if __name__ == "__main__":
    main()
