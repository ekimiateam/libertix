from __future__ import annotations

import argparse
import hashlib
import json
import pwd
import re
import subprocess
from pathlib import Path


def verify(plan: dict, receipt: dict) -> None:
    inventory = plan["features"]["windowsSharing"]
    volumes = [
        volume
        for volume in inventory["volumes"]
        if volume["windowsVolumeId"].casefold() == receipt["volume_id"].casefold()
    ]
    if len(volumes) != 1:
        raise ValueError("The redirected Documents volume is absent from the installation plan")
    relative = receipt["destination"][3:].replace("\\", "/")
    folders = [
        folder
        for folder in inventory["folders"]
        if folder["profileSid"] == receipt["user_sid"]
        and folder["ntfsUuid"] == volumes[0]["ntfsUuid"]
        and folder["relativePath"].casefold() == relative.casefold()
    ]
    if len(folders) != 1:
        raise ValueError("The redirected Documents path is absent or ambiguous")
    home = Path(pwd.getpwnam(plan["account"]["username"]).pw_dir)
    shortcut = home / folders[0]["shortcut"]
    if not shortcut.is_symlink():
        raise ValueError("The redirected Documents shortcut is missing")
    target = shortcut.resolve(strict=True)
    metadata = subprocess.run(
        ["findmnt", "-J", "-T", str(target), "-o", "UUID,FSTYPE,OPTIONS"],
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    )
    filesystem = json.loads(metadata.stdout)["filesystems"]
    if (
        len(filesystem) != 1
        or str(filesystem[0].get("uuid", "")).upper() != volumes[0]["ntfsUuid"]
        or filesystem[0].get("fstype") not in {"ntfs", "ntfs3", "fuseblk"}
        or "rw" not in filesystem[0]["options"].split(",")
    ):
        raise ValueError("Documents is not on the recorded writable volume")
    witness = receipt["witness"]
    if not re.fullmatch(
        r"libertix-user-data-[0-9a-f]{32}\.txt", witness["relative"]
    ) or not re.fullmatch(r"[0-9a-fA-F]{64}", witness["sha256"]):
        raise ValueError("The redirected Documents witness is invalid")
    path = shortcut / witness["relative"]
    if path.is_symlink() or not path.resolve(strict=True).is_relative_to(target):
        raise ValueError("The redirected Documents witness escapes its directory")
    with path.open("rb") as stream:
        digest = hashlib.sha256(stream.read(4096)).hexdigest()
        if stream.read(1):
            raise ValueError("The Documents fixture witness unexpectedly grew")
    if digest.upper() != witness["sha256"].upper():
        raise ValueError("The Windows-only Documents witness differs under Linux")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    plan = json.loads(Path("/etc/libertix/installation-plan.json").read_text())
    verify(plan, json.loads(args.receipt))
    print("REDIRECTED_DOCUMENTS=OK")


if __name__ == "__main__":
    main()
