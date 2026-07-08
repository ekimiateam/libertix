#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import subprocess
import tkinter as tk
import time
from pathlib import Path


LOG_DIR = Path("/run/libertix")
LOG = LOG_DIR / "install.log"
STAGE_FILE = LOG_DIR / "stage"
FAIL_FILE = LOG_DIR / "failure"
RESULT_FILE = LOG_DIR / "result.env"
DEV_FILE = LOG_DIR / "dev-terminal"
READY_FILE = LOG_DIR / "gui-ready"
HEARTBEAT_FILE = LOG_DIR / "gui-heartbeat"
BUILD_ID_FILE = Path("/etc/libertix-build-id")

STAGES = {
    "runner-start": ("Demarrage de l'installateur", 1),
    "005-wait-prereqs": ("Detection du live et du disque", 3),
    "006-clean-windows-live-boot": ("Nettoyage du boot temporaire Windows", 5),
    "007-windows-live-boot-cleaned": ("Boot temporaire nettoye", 7),
    "010-read-config": ("Lecture de la configuration", 10),
    "020-detect-disk": ("Detection des partitions", 14),
    "030-check-mint-iso": ("Verification de l'ISO Mint", 18),
    "035-umount-windows": ("Liberation de la partition Windows", 22),
    "040-unmount-target-disk": ("Liberation du disque cible", 26),
    "050-assert-live-detached": ("Verification du live en RAM", 30),
    "060-set-mbr-type-83": ("Preparation de la partition Linux", 34),
    "060-set-linux-partition-type": ("Preparation de la partition Linux", 34),
    "070-wipefs-live-part": ("Nettoyage de l'ancien systeme de fichiers", 38),
    "080-mkfs-ext4": ("Creation du systeme de fichiers Linux", 42),
    "090-mount-target": ("Montage de la cible Linux", 46),
    "100-remount-windows-ro": ("Remontage lecture seule de Windows", 50),
    "110-loop-mount-mint-iso": ("Montage de l'ISO Mint", 54),
    "120-unsquashfs": ("Extraction de Mint", 64),
    "130-target-system-config": ("Configuration du systeme installe", 76),
    "140-install-bootloader": ("Installation du bootloader", 90),
    "150-final-verify": ("Verification finale", 98),
    "installer-success": ("Installation terminee", 100),
}

UNSQUASHFS_STAGE_START = 54
UNSQUASHFS_STAGE_END = 76

def read_text(path: Path, default: str = "") -> str:
    try:
        return path.read_text(errors="replace").strip()
    except OSError:
        return default


def tail(path: Path, lines: int) -> str:
    try:
        data = path.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(data[-lines:])


def log_since_stage(stage: str) -> str:
    lines = read_text(LOG).replace("\r", "\n").splitlines()
    start = -1
    for index, line in enumerate(lines):
        if line.strip() == f"STAGE: {stage}":
            start = index
    if start < 0:
        return ""
    return "\n".join(lines[start + 1 :])


def parse_unsquashfs_percent() -> int | None:
    text = log_since_stage("120-unsquashfs")
    if not text:
        return None

    values: list[int] = []
    for match in re.finditer(r"(?<!\d)(\d{1,3})\s*%", text):
        value = int(match.group(1))
        if 0 <= value <= 100:
            values.append(value)

    for match in re.finditer(r"(?<!\d)(\d+)\s*/\s*(\d+)(?!\d)", text):
        done = int(match.group(1))
        total = int(match.group(2))
        if total > 0:
            values.append(max(0, min(100, int(done * 100 / total))))

    return max(values) if values else None


def detailed_logs() -> str:
    sections: list[str] = []
    if STAGE_FILE.exists():
        sections.append("===== stage =====\n" + read_text(STAGE_FILE))
    if FAIL_FILE.exists() and FAIL_FILE.stat().st_size:
        sections.append("===== failure =====\n" + read_text(FAIL_FILE))
    if RESULT_FILE.exists():
        sections.append("===== result.env =====\n" + read_text(RESULT_FILE))
    if LOG.exists():
        sections.append("===== install.log =====\n" + tail(LOG, 5000))
    debug_log = LOG_DIR / "debug.log"
    if debug_log.exists() and debug_log.stat().st_size:
        sections.append("===== debug.log =====\n" + tail(debug_log, 700))
    return "\n\n".join(section for section in sections if section.strip())


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in read_text(path).splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def stage_info(stage: str) -> tuple[str, int]:
    if stage.startswith("installer-failed-"):
        return "Installation echouee", 100
    return STAGES.get(stage, (stage or "Etat inconnu", 1))


def progress_info(stage: str) -> tuple[str, int, str]:
    label, percent = stage_info(stage)
    if stage == "120-unsquashfs":
        sub_percent = parse_unsquashfs_percent()
        if sub_percent is not None:
            percent = UNSQUASHFS_STAGE_START + (
                (UNSQUASHFS_STAGE_END - UNSQUASHFS_STAGE_START) * sub_percent // 100
            )
            return label, percent, f"Extraction Mint: {sub_percent}%"
        return label, UNSQUASHFS_STAGE_START, "Extraction Mint: initialisation"
    return label, percent, ""


def short_failure_message(rc: str) -> str:
    failure = read_text(FAIL_FILE)
    if not failure:
        return f"rc={rc}"

    values = parse_env(FAIL_FILE)
    lines: list[str] = []
    if values.get("stage"):
        lines.append(f"Etape: {values['stage']}")
    if values.get("error"):
        lines.append(values["error"])
    elif values.get("cmd"):
        lines.append(f"Commande: {values['cmd']}")
    if values.get("rc"):
        lines.append(f"rc={values['rc']}")

    if lines:
        return "\n".join(lines)
    return failure


class LibertixGui:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("Libertix Installer")
        self.root.configure(bg="#0b1020")
        self.root.overrideredirect(True)
        self.root.attributes("-fullscreen", True)
        self.root.geometry(f"{self.root.winfo_screenwidth()}x{self.root.winfo_screenheight()}+0+0")
        for sequence in (
            "<F12>",
            "<KeyPress-F12>",
            "<Control-Alt-d>",
            "<Control-Alt-D>",
            "<Control-Alt-KeyPress-d>",
            "<Control-Alt-KeyPress-D>",
        ):
            self.root.bind_all(sequence, self.enter_dev_mode)
        self.root.bind("<Configure>", self.on_resize)
        self.details_visible = False
        self.dev_requested = False
        self.last_size: tuple[int, int] = (0, 0)
        self.current_percent = 0
        self.progress_running = True
        self.progress_tick = 0
        self.subprogress_text = ""
        self.last_log_text = ""

        self.container = tk.Frame(self.root, bg="#0b1020")
        self.container.place(x=0, y=0, relwidth=1, relheight=1)

        self.logo = tk.Label(
            self.container,
            text="Libertix",
            fg="#f8fafc",
            bg="#0b1020",
            font=("DejaVu Sans", 54, "bold"),
        )
        self.logo.pack(anchor="w")

        self.subtitle = tk.Label(
            self.container,
            text="Installation automatique",
            fg="#9fb3c8",
            bg="#0b1020",
            font=("DejaVu Sans", 18),
        )
        self.subtitle.pack(anchor="w", pady=(0, 28))

        self.stage_label = tk.Label(
            self.container,
            text="Demarrage",
            fg="#f8fafc",
            bg="#0b1020",
            font=("DejaVu Sans", 26, "bold"),
        )
        self.stage_label.pack(anchor="w")

        self.code_label = tk.Label(
            self.container,
            text="",
            fg="#8ea2b8",
            bg="#0b1020",
            font=("DejaVu Sans Mono", 13),
        )
        self.code_label.pack(anchor="w", pady=(6, 18))

        self.progress_canvas = tk.Canvas(
            self.container,
            height=30,
            bg="#111827",
            highlightthickness=0,
        )
        self.progress_canvas.pack(fill=tk.X, pady=(0, 8))

        self.percent_label = tk.Label(
            self.container,
            text="0%",
            fg="#dbeafe",
            bg="#0b1020",
            font=("DejaVu Sans", 15, "bold"),
        )
        self.percent_label.pack(anchor="e", pady=(0, 2))

        self.subprogress_label = tk.Label(
            self.container,
            text="",
            fg="#93c5fd",
            bg="#0b1020",
            font=("DejaVu Sans", 12),
        )
        self.subprogress_label.pack(anchor="e", pady=(0, 20))

        self.message_label = tk.Label(
            self.container,
            text="Preparation...",
            fg="#d1d5db",
            bg="#0b1020",
            font=("DejaVu Sans", 16),
            justify=tk.LEFT,
            wraplength=1100,
        )
        self.message_label.pack(anchor="w", fill=tk.X, pady=(0, 18))

        self.button_bar = tk.Frame(self.container, bg="#0b1020")
        self.button_bar.pack(anchor="w", fill=tk.X, pady=(0, 18))

        self.details_button = tk.Button(
            self.button_bar,
            text="Plus de details",
            command=self.toggle_details,
            font=("DejaVu Sans", 14),
            padx=18,
            pady=8,
        )
        self.details_button.pack(side=tk.LEFT)

        self.reboot_button = tk.Button(
            self.button_bar,
            text="Reboot",
            command=self.reboot,
            font=("DejaVu Sans", 14, "bold"),
            padx=22,
            pady=8,
        )

        self.details_frame = tk.Frame(self.container, bg="#0b1020")
        self.log_text = tk.Text(
            self.details_frame,
            height=18,
            bg="#020617",
            fg="#e5e7eb",
            insertbackground="#e5e7eb",
            font=("DejaVu Sans Mono", 11),
            wrap=tk.NONE,
            relief=tk.FLAT,
            padx=14,
            pady=12,
        )
        self.scroll = tk.Scrollbar(self.details_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=self.scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.footer = tk.Label(
            self.container,
            text="F12: mode terminal",
            fg="#64748b",
            bg="#0b1020",
            font=("DejaVu Sans", 11),
        )
        self.footer.pack(side=tk.BOTTOM, anchor="w")

        self.apply_layout()
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.root.after(100, self.force_front)
        self.root.after(700, self.mark_ready)
        self.root.after(200, self.refresh)
        self.root.after(120, self.animate_progress)

    def scaled(self, width: int, height: int, base: int, minimum: int, maximum: int) -> int:
        scale = min(width / 1024, height / 768)
        return max(minimum, min(maximum, int(base * scale)))

    def on_resize(self, _event: object | None = None) -> None:
        size = (self.root.winfo_width(), self.root.winfo_height())
        if size != self.last_size:
            self.last_size = size
            self.apply_layout()

    def apply_layout(self) -> None:
        width = max(self.root.winfo_width(), self.root.winfo_screenwidth(), 800)
        height = max(self.root.winfo_height(), self.root.winfo_screenheight(), 600)
        pad_x = self.scaled(width, height, 56, 28, 96)
        pad_y = self.scaled(width, height, 18 if self.details_visible else 42, 12, 72)
        logo_font = self.scaled(width, height, 62, 38, 86)
        subtitle_font = self.scaled(width, height, 20, 13, 28)
        stage_font = self.scaled(width, height, 30, 18, 42)
        code_font = self.scaled(width, height, 13, 10, 18)
        body_font = self.scaled(width, height, 17, 12, 24)
        button_font = self.scaled(width, height, 12, 9, 15)
        log_font = self.scaled(width, height, 11, 8, 16)
        progress_height = self.scaled(width, height, 34, 22, 48)

        self.container.configure(padx=pad_x, pady=pad_y)
        self.logo.configure(font=("DejaVu Sans", logo_font, "bold"))
        self.subtitle.configure(font=("DejaVu Sans", subtitle_font))
        self.stage_label.configure(font=("DejaVu Sans", stage_font, "bold"), wraplength=max(360, width - pad_x * 2))
        self.code_label.configure(font=("DejaVu Sans Mono", code_font))
        self.progress_canvas.configure(height=progress_height)
        self.percent_label.configure(font=("DejaVu Sans", body_font, "bold"))
        self.subprogress_label.configure(font=("DejaVu Sans", max(10, body_font - 4)))
        self.message_label.configure(font=("DejaVu Sans", body_font), wraplength=max(360, width - pad_x * 2))
        self.details_button.configure(font=("DejaVu Sans", button_font), padx=max(8, button_font - 1), pady=max(4, button_font // 3))
        self.reboot_button.configure(font=("DejaVu Sans", button_font, "bold"), padx=max(10, button_font + 1), pady=max(4, button_font // 3))
        log_reserved_height = 150 if self.details_visible else 460
        self.log_text.configure(
            font=("DejaVu Sans Mono", log_font),
            height=max(8, (height - log_reserved_height) // max(log_font + 8, 1)),
        )
        self.footer.configure(font=("DejaVu Sans", max(9, button_font - 3)))
        self.set_progress(
            self.current_percent,
            running=self.progress_running,
            subprogress=self.subprogress_text,
        )

    def pack_summary_widgets(self) -> None:
        self.logo.pack(anchor="w", before=self.button_bar)
        self.subtitle.pack(anchor="w", pady=(0, 28), after=self.logo)
        self.stage_label.pack(anchor="w", after=self.subtitle)
        self.code_label.pack(anchor="w", pady=(6, 18), after=self.stage_label)
        self.progress_canvas.pack(fill=tk.X, pady=(0, 8), after=self.code_label)
        self.percent_label.pack(anchor="e", pady=(0, 2), after=self.progress_canvas)
        self.subprogress_label.pack(anchor="e", pady=(0, 20), after=self.percent_label)
        self.message_label.pack(anchor="w", fill=tk.X, pady=(0, 18), after=self.subprogress_label)

    def unpack_summary_widgets(self) -> None:
        for widget in (
            self.logo,
            self.subtitle,
            self.stage_label,
            self.code_label,
            self.progress_canvas,
            self.percent_label,
            self.subprogress_label,
            self.message_label,
        ):
            widget.pack_forget()

    def force_front(self) -> None:
        width = self.root.winfo_screenwidth()
        height = self.root.winfo_screenheight()
        self.root.geometry(f"{width}x{height}+0+0")
        self.root.lift()
        self.root.focus_force()

    def mark_ready(self) -> None:
        if self.dev_requested:
            return
        self.force_front()
        READY_FILE.write_text(f"true {time.time():.3f}\n")
        self.heartbeat()

    def heartbeat(self) -> None:
        if self.dev_requested:
            return
        HEARTBEAT_FILE.write_text(f"{time.time():.3f}\n")
        self.root.after(1000, self.heartbeat)

    def toggle_details(self) -> None:
        self.details_visible = not self.details_visible
        self.details_button.configure(text="Masquer les details" if self.details_visible else "Plus de details")
        if self.details_visible:
            self.unpack_summary_widgets()
            self.details_frame.pack(fill=tk.BOTH, expand=True, pady=(8, 10))
        else:
            self.details_frame.pack_forget()
            self.pack_summary_widgets()
        self.apply_layout()

    def enter_dev_mode(self, _event: object | None = None) -> None:
        if self.dev_requested:
            return
        self.dev_requested = True
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        DEV_FILE.write_text(f"true {time.time():.3f}\n")
        for path in (READY_FILE, HEARTBEAT_FILE):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        subprocess.run(["chvt", "1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        self.root.after(50, self.root.destroy)

    def reboot(self) -> None:
        self.reboot_button.configure(state=tk.DISABLED, text="Reboot en cours...")
        subprocess.Popen(["systemctl", "reboot", "-i"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def draw_progress(self) -> None:
        self.progress_canvas.delete("all")
        width = max(self.progress_canvas.winfo_width(), 1)
        height = max(self.progress_canvas.winfo_height(), 1)
        filled = int(width * max(0, min(self.current_percent, 100)) / 100)
        self.progress_canvas.create_rectangle(0, 0, width, height, fill="#1f2937", outline="")
        self.progress_canvas.create_rectangle(0, 0, filled, height, fill="#38bdf8", outline="")
        self.percent_label.configure(text=f"{self.current_percent}%")
        self.subprogress_label.configure(text=self.subprogress_text)

    def set_progress(self, percent: int, *, running: bool, subprogress: str = "") -> None:
        self.current_percent = max(0, min(percent, 100))
        self.progress_running = running
        self.subprogress_text = subprogress
        self.draw_progress()

    def animate_progress(self) -> None:
        if self.progress_running:
            self.progress_tick = (self.progress_tick + 1) % 4
            base_text = self.subprogress_text.rstrip(".")
            if base_text:
                self.subprogress_label.configure(text=base_text + "." * self.progress_tick)
        self.root.after(500, self.animate_progress)

    def refresh(self) -> None:
        stage = read_text(STAGE_FILE, "runner-start")
        result = parse_env(RESULT_FILE)
        label, percent, subprogress = progress_info(stage)
        build = read_text(BUILD_ID_FILE, "unknown")
        success = result.get("LIBERTIX_INSTALL_SUCCESS")
        rc = result.get("LIBERTIX_INSTALL_RC")
        finished = success == "true" or (success == "false" and rc is not None)

        self.stage_label.configure(text=label)
        self.code_label.configure(text=f"Build: {build}    Code: {stage}")
        self.set_progress(percent, running=not finished, subprogress=subprogress)

        if success == "true":
            self.message_label.configure(
                text="Installation terminee et verifiee. Redemarrage automatique dans quelques secondes.",
                fg="#bbf7d0",
            )
            self.reboot_button.pack_forget()
        elif success == "false" and rc is not None:
            self.message_label.configure(
                text=f"Erreur pendant l'installation.\n{short_failure_message(rc)}",
                fg="#fecaca",
            )
            if not self.reboot_button.winfo_ismapped():
                self.reboot_button.pack(side=tk.LEFT, padx=(12, 0))
        else:
            self.message_label.configure(text=label, fg="#d1d5db")
            self.reboot_button.pack_forget()

        first, last = self.log_text.yview()
        follow_tail = not self.details_visible or last > 0.98

        log_text = detailed_logs() if self.details_visible else tail(LOG, 240)
        if log_text != self.last_log_text:
            self.last_log_text = log_text
            self.log_text.configure(state=tk.NORMAL)
            self.log_text.delete("1.0", tk.END)
            self.log_text.insert(tk.END, log_text)
            self.log_text.configure(state=tk.DISABLED)
            if follow_tail:
                self.log_text.see(tk.END)
            else:
                self.log_text.yview_moveto(first)

        self.root.after(700, self.refresh)

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")
    LibertixGui().run()
