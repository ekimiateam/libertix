from __future__ import annotations

import base64
import hashlib
import importlib.util
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest
from PIL import Image, ImageDraw


@pytest.fixture
def checker(monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    path = Path(__file__).parents[1] / "app/scripts/check_linux_preference_migration.py"
    spec = importlib.util.spec_from_file_location("preference_evidence", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "verify_image_decodes", lambda _: None)
    return module


@pytest.fixture
def wallpaper(tmp_path: Path) -> Path:
    directory = tmp_path / "Pictures" / "Libertix"
    directory.mkdir(parents=True)
    path = directory / "windows-wallpaper.png"
    path.write_bytes(b"test wallpaper")
    return path


@pytest.mark.parametrize("prefix", ["org.cinnamon", "org.gnome"])
def test_wallpaper_evidence_checks_selected_uri_not_only_the_file(
    checker: ModuleType, wallpaper: Path, monkeypatch: pytest.MonkeyPatch, prefix: str
) -> None:
    calls = []

    def get(schema: str, key: str) -> str:
        calls.append((schema, key))
        return "'" + wallpaper.as_uri() + "'"

    monkeypatch.setattr(checker, "gsettings_get", get)
    home = wallpaper.parents[2]
    digest = hashlib.sha256(wallpaper.read_bytes()).hexdigest()
    checker.verify_wallpaper(home, prefix, digest)
    assert calls == [(f"{prefix}.desktop.background", "picture-uri")] + (
        [(f"{prefix}.desktop.background", "picture-uri-dark")] if prefix == "org.gnome" else []
    )
    monkeypatch.setattr(checker, "gsettings_get", lambda *_: "'file:///wrong.png'")
    with pytest.raises(RuntimeError, match="GSettings mismatch"):
        checker.verify_wallpaper(home, prefix, digest)


@pytest.mark.parametrize("target", ["Pictures", "Libertix", "windows-wallpaper.png"])
def test_wallpaper_evidence_rejects_foreign_ownership(
    checker: ModuleType, wallpaper: Path, monkeypatch: pytest.MonkeyPatch, target: str
) -> None:
    original = Path.lstat

    def metadata(path: Path) -> object:
        value = original(path)
        if path.name == target:
            return SimpleNamespace(st_uid=os.geteuid() + 1, st_mode=value.st_mode)
        return value

    monkeypatch.setattr(Path, "lstat", metadata)
    with pytest.raises(RuntimeError, match="owned by the installed user"):
        checker.verify_wallpaper(wallpaper.parents[2], "org.gnome", "0" * 64)


def test_wallpaper_evidence_rejects_symlink(checker: ModuleType, tmp_path: Path) -> None:
    image = tmp_path / "image.png"
    image.write_bytes(b"test")
    link = tmp_path / "linked.png"
    link.symlink_to(image)
    with pytest.raises(RuntimeError, match="regular file"):
        checker.verify_user_asset(link, hashlib.sha256(b"test").hexdigest())


def test_asset_evidence_rejects_undecodable_image_even_with_matching_hash(
    checker: ModuleType, wallpaper: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def reject(path: Path) -> None:
        assert path == wallpaper
        raise RuntimeError("invalid image")

    monkeypatch.setattr(checker, "verify_image_decodes", reject)
    with pytest.raises(RuntimeError, match="invalid image"):
        checker.verify_user_asset(wallpaper, hashlib.sha256(wallpaper.read_bytes()).hexdigest())


@pytest.mark.parametrize("prefix", ["org.cinnamon", "org.gnome"])
@pytest.mark.parametrize("case", ["default", "changed", "missing-file", "copied-windows"])
def test_default_wallpaper_evidence_checks_both_backgrounds_and_the_actual_file(
    checker: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, prefix: str, case: str
) -> None:
    image = tmp_path / "linux-default.jpg"
    image.write_bytes(b"default image")
    calls = []

    class Value:
        def __init__(self, uri):
            self.uri = uri

        def unpack(self):
            return self.uri

        def __eq__(self, other):
            return isinstance(other, Value) and self.uri == other.uri

    class Settings:
        @staticmethod
        def new(schema):
            assert schema == prefix + ".desktop.background"
            return Settings()

        def get_default_value(self, key):
            calls.append(key)
            return Value(image.as_uri())

        def get_value(self, key):
            return Value("file:///changed.jpg" if case == "changed" else image.as_uri())

    gio = SimpleNamespace(
        Settings=Settings,
        File=SimpleNamespace(
            new_for_uri=lambda _: SimpleNamespace(
                get_path=lambda: (
                    str(tmp_path / "missing.jpg") if case == "missing-file" else str(image)
                )
            )
        ),
    )
    monkeypatch.setitem(sys.modules, "gi.repository", SimpleNamespace(Gio=gio))
    if case == "copied-windows":
        folder = tmp_path / "Pictures" / "Libertix"
        folder.mkdir(parents=True)
        (folder / "windows-wallpaper.jpg").write_bytes(b"unwanted copy")
    if case != "default":
        with pytest.raises(RuntimeError):
            checker.verify_default_wallpaper(tmp_path, prefix)
    else:
        checker.verify_default_wallpaper(tmp_path, prefix)
        assert calls == ["picture-uri"] + (["picture-uri-dark"] if prefix == "org.gnome" else [])


@pytest.mark.parametrize("kind", ["colored", "black", "old-malformed"])
def test_actual_desktop_decoder_rejects_the_old_fixture_and_black_images(
    tmp_path: Path, kind: str
) -> None:
    python = Path("/usr/bin/python3")
    if (
        not python.is_file()
        or subprocess.run(
            [str(python), "-c", "import gi; gi.require_version('GdkPixbuf', '2.0')"],
            capture_output=True,
            check=False,
        ).returncode
    ):
        pytest.skip("The system GdkPixbuf Python binding is unavailable")
    image = tmp_path / "image.png"
    if kind == "old-malformed":
        image.write_bytes(
            base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR4nGP4z8DAwMDAxMDAwAAAHgIB8xW9xQAAAABJRU5ErkJggg=="
            )
        )
    else:
        bitmap = Image.new("RGB", (1280, 720), "cornflowerblue" if kind == "colored" else "black")
        if kind == "colored":
            ImageDraw.Draw(bitmap).ellipse((960, 80, 1120, 240), fill="gold")
        bitmap.save(image)
    checker_path = Path(__file__).parents[1] / "app/scripts/check_linux_preference_migration.py"
    result = subprocess.run(
        [
            str(python),
            "-c",
            "import runpy,sys; from pathlib import Path; "
            "runpy.run_path(sys.argv[1])['verify_image_decodes'](Path(sys.argv[2]))",
            str(checker_path),
            str(image),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) == (kind == "colored"), result.stderr
