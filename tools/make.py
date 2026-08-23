#!/usr/bin/env python3
"""Build an E-Ink-friendly BWR1 file from an authorized video source.

BWR1 is a small, seekable container for KOReader on E-Ink hardware:
    header: 32 bytes, little-endian
    frames: 1-bit pixels, MSB first, row-major, 1 = white / 0 = black

The script never implements website-specific stream extraction, DRM bypassing,
or authentication scraping.  Give it either a direct media URL/file path or a
trusted JSON API that returns a direct, authorized media URL.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
from typing import Any
from urllib.request import Request, urlopen

import numpy as np

MAGIC = b"BWR1"
VERSION = 1
PIXEL_FORMAT_MONO1_MSB_WHITE = 1
HEADER = struct.Struct("<4sBBHHHII12s")
def find_ffmpeg() -> str:
    """Return a usable FFmpeg executable path when one is discoverable."""
    candidates = [
        shutil.which("ffmpeg"),
        "/data/data/com.termux/files/usr/bin/ffmpeg",
        "/data/data/com.termux/files/usr/bin/ffmpeg.exe",
        "/usr/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return "ffmpeg"


def validate_ffmpeg_path(path: str) -> None:
    resolved = shutil.which(path) if "/" not in path else path
    if not resolved or not Path(resolved).is_file() or not os.access(resolved, os.X_OK):
        fail(
            "FFmpeg wurde nicht gefunden. Das PyPI-Paket 'ffmpeg' ist nur ein Python-Wrapper "
            "und enthält nicht die ausführbare FFmpeg-Datei. Wähle im Feld 'FFmpeg' den "
            "echten Binary-Pfad, zum Beispiel /data/data/com.termux/files/usr/bin/ffmpeg."
        )


BAYER_8 = np.array(
    [
        [0, 48, 12, 60, 3, 51, 15, 63],
        [32, 16, 44, 28, 35, 19, 47, 31],
        [8, 56, 4, 52, 11, 59, 7, 55],
        [40, 24, 36, 20, 43, 27, 39, 23],
        [2, 50, 14, 62, 1, 49, 13, 61],
        [34, 18, 46, 30, 33, 17, 45, 29],
        [10, 58, 6, 54, 9, 57, 5, 53],
        [42, 26, 38, 22, 41, 25, 45, 21],
    ],
    dtype=np.uint8,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    origin = parser.add_mutually_exclusive_group(required=True)
    origin.add_argument("--source-url", help="Authorized direct media URL or local filename.")
    origin.add_argument("--api-url", help="Trusted JSON endpoint returning a direct source URL.")
    parser.add_argument("--api-token", default=os.getenv("VIDEO_API_TOKEN"), help="Optional bearer token; prefer a CI secret.")
    parser.add_argument("--output", type=Path, required=True, help="Target .bwr file.")
    parser.add_argument("--audio-output", type=Path, default=None, help="Optional target WAV file; defaults to the BWR1 basename.")
    parser.add_argument("--width", type=int, default=1264, help="Output width; Kobo Libra Colour default: 1264.")
    parser.add_argument("--height", type=int, default=1680, help="Output height; Kobo Libra Colour default: 1680.")
    parser.add_argument("--fps", type=float, default=12.0, help="Output frame rate (0.01–30.00).")
    parser.add_argument("--start", type=float, default=None, help="Optional start time in seconds.")
    parser.add_argument("--duration", type=float, default=None, help="Optional maximum duration in seconds.")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg executable path.")
    return parser.parse_args()


def fail(message: str) -> None:
    raise RuntimeError(message)


def validate_geometry(width: int, height: int, fps: float) -> None:
    if not (1 <= width <= 4096 and 1 <= height <= 4096):
        fail("Width and height must be in the range 1–4096.")
    if width % 8 != 0:
        fail("Width must be divisible by 8 for the current 1-bit packed BWR1 layout.")
    if not (0.01 <= fps <= 30.00):
        fail("FPS must be between 0.01 and 30.00.")


def resolve_api(api_url: str, token: str | None) -> tuple[str, dict[str, Any]]:
    headers = {"Accept": "application/json", "User-Agent": "kobo-raw-video-action/1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(api_url, headers=headers, method="GET")
    with urlopen(request, timeout=30) as response:  # nosec B310: supplied by repository owner
        charset = response.headers.get_content_charset() or "utf-8"
        payload = json.loads(response.read().decode(charset))
    if not isinstance(payload, dict):
        fail("The API response must be a JSON object.")
    source_url = payload.get("source_url") or payload.get("url") or payload.get("source")
    if not isinstance(source_url, str) or not source_url:
        fail("The API response needs source_url, url, or source with a direct media URL.")
    if source_url.startswith("-"):
        fail("The source URL must not begin with a dash.")
    return source_url, payload


def make_filter(width: int, height: int, fps: float) -> str:
    return (
        f"fps=fps={fps:g},"
        f"scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=white,format=gray"
    )


def ffmpeg_command(args: argparse.Namespace, source: str, start: float | None, duration: float | None, audio_output: Path) -> list[str]:
    command = [args.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error"]
    if start is not None:
        if start < 0:
            fail("Start must not be negative.")
        command.extend(["-ss", f"{start:.3f}"])
    command.extend(["-i", source])
    if duration is not None:
        if duration <= 0:
            fail("Duration must be positive.")
        command.extend(["-t", f"{duration:.3f}"])
    command.extend([
        "-an", "-sn", "-dn",
        "-vf", make_filter(args.width, args.height, args.fps),
        "-pix_fmt", "gray",
        "-f", "rawvideo",
        "pipe:1",
        "-map", "0:a:0?", "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2",
        "-f", "wav", str(audio_output),
    ])
    return command


def bayer_dither_and_pack(frame: bytes, width: int, height: int) -> bytes:
    gray = np.frombuffer(frame, dtype=np.uint8).reshape((height, width))
    tiled_thresholds = np.tile(BAYER_8, (math.ceil(height / 8), math.ceil(width / 8)))[:height, :width]
    # 1 means white. Values are precisely one bit before packing.
    mono = gray > (tiled_thresholds * 4 + 2)
    return np.packbits(mono, axis=1, bitorder="big").tobytes()


def convert(args: argparse.Namespace, progress_callback=None) -> dict[str, Any]:
    validate_geometry(args.width, args.height, args.fps)
    validate_ffmpeg_path(args.ffmpeg)
    source = args.source_url
    api_payload: dict[str, Any] = {}
    if args.api_url:
        source, api_payload = resolve_api(args.api_url, args.api_token)

    start = args.start if args.start is not None else api_payload.get("start_s")
    duration = args.duration if args.duration is not None else api_payload.get("duration_s")
    start = float(start) if start is not None else None
    duration = float(duration) if duration is not None else None

    frame_input_bytes = args.width * args.height
    frame_output_bytes = (args.width // 8) * args.height
    audio_output = args.audio_output or args.output.with_suffix(".wav")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    audio_output.parent.mkdir(parents=True, exist_ok=True)
    # Android often permits reading from shared storage but refuses creating
    # sibling files such as video.bwr.partial. Build in the app/system temp
    # directory and copy the completed file to the selected destination.
    temporary = Path(tempfile.mkstemp(prefix="kobo-bwr-", suffix=".partial")[1])
    temporary.unlink(missing_ok=True)
    audio_temporary = Path(tempfile.mkstemp(prefix="kobo-audio-", suffix=".wav.partial")[1])
    audio_temporary.unlink(missing_ok=True)

    command = ffmpeg_command(args, source, start, duration, audio_temporary)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    frame_count = 0
    try:
        with temporary.open("wb") as out:
            out.write(HEADER.pack(
                MAGIC, VERSION, PIXEL_FORMAT_MONO1_MSB_WHITE,
                args.width, args.height, round(args.fps * 100),
                0, frame_output_bytes, b"\0" * 12,
            ))
            assert process.stdout is not None
            while True:
                frame = process.stdout.read(frame_input_bytes)
                if not frame:
                    break
                if len(frame) != frame_input_bytes:
                    fail("FFmpeg produced an incomplete raw frame.")
                out.write(bayer_dither_and_pack(frame, args.width, args.height))
                frame_count += 1
                if progress_callback:
                    progress_callback(frame_count)
    finally:
        if process.stdout:
            process.stdout.close()

    stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
    return_code = process.wait()
    if return_code != 0:
        temporary.unlink(missing_ok=True)
        fail("FFmpeg failed: " + (stderr.strip() or f"exit status {return_code}"))
    if frame_count == 0:
        temporary.unlink(missing_ok=True)
        audio_temporary.unlink(missing_ok=True)
        fail("The source produced no video frames.")
    if not audio_temporary.exists() or audio_temporary.stat().st_size <= 44:
        temporary.unlink(missing_ok=True)
        audio_temporary.unlink(missing_ok=True)
        fail("The source contains no audio track that FFmpeg could export as WAV.")

    with temporary.open("r+b") as out:
        out.write(HEADER.pack(
            MAGIC, VERSION, PIXEL_FORMAT_MONO1_MSB_WHITE,
            args.width, args.height, round(args.fps * 100),
            frame_count, frame_output_bytes, b"\0" * 12,
        ))
    try:
        shutil.copyfile(temporary, args.output)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        fail(f"Cannot write the output file '{args.output}'. Choose a writable folder, for example the app's Documents folder. Details: {exc}")
    temporary.unlink(missing_ok=True)
    try:
        shutil.copyfile(audio_temporary, audio_output)
    except OSError as exc:
        audio_temporary.unlink(missing_ok=True)
        fail(f"Cannot write the WAV file '{audio_output}'. Choose a writable folder. Details: {exc}")
    audio_temporary.unlink(missing_ok=True)

    metadata = {
        "format": "BWR1",
        "version": VERSION,
        "pixel_format": "mono1-msb-white",
        "width": args.width,
        "height": args.height,
        "fps": args.fps,
        "frames": frame_count,
        "duration_s": round(frame_count / args.fps, 3),
        "frame_bytes": frame_output_bytes,
        "source_title": api_payload.get("title"),
        "source_id": api_payload.get("id"),
        "audio_format": "WAV PCM s16le, 44100 Hz, stereo",
        "audio_file": str(audio_output),
    }
    metadata_path = args.output.with_suffix(args.output.suffix + ".json")
    try:
        metadata_temp = Path(tempfile.mkstemp(prefix="kobo-bwr-meta-", suffix=".partial")[1])
        metadata_temp.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        shutil.copyfile(metadata_temp, metadata_path)
    finally:
        if "metadata_temp" in locals():
            metadata_temp.unlink(missing_ok=True)
    return metadata


def run_gui() -> int:
    import threading
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    root = tk.Tk()
    root.title("Kobo BWR1-Konverter")
    root.geometry("760x560")
    root.minsize(650, 500)

    source_var = tk.StringVar()
    api_var = tk.StringVar()
    token_var = tk.StringVar()
    output_var = tk.StringVar(value=str(Path.cwd() / "video.bwr"))
    audio_output_var = tk.StringVar(value=str(Path.cwd() / "video.wav"))
    ffmpeg_var = tk.StringVar(value=find_ffmpeg())
    width_var = tk.StringVar(value="1264")
    height_var = tk.StringVar(value="1680")
    fps_var = tk.StringVar(value="12")
    start_var = tk.StringVar()
    duration_var = tk.StringVar(value="30")
    status_var = tk.StringVar(value="Bereit")
    progress_var = tk.DoubleVar(value=0)

    def add_row(parent, row, label, variable, browse_command=None, show=None):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=6, pady=5)
        entry = ttk.Entry(parent, textvariable=variable, show=show or "")
        entry.grid(row=row, column=1, sticky="ew", padx=6, pady=5)
        if browse_command:
            ttk.Button(parent, text="Auswählen", command=browse_command).grid(row=row, column=2, padx=6, pady=5)
        return entry

    def choose_source():
        path = filedialog.askopenfilename(
            title="Videodatei auswählen",
            filetypes=[("Video", "*.mp4 *.mkv *.webm *.mov *.avi"), ("Alle Dateien", "*.*")],
        )
        if path:
            source_var.set(path)

    def choose_output():
        path = filedialog.asksaveasfilename(
            title="BWR1-Ausgabedatei speichern",
            defaultextension=".bwr",
            filetypes=[("BWR1 RAW Video", "*.bwr"), ("Alle Dateien", "*.*")],
        )
        if path:
            output_var.set(path)
            audio_output_var.set(str(Path(path).with_suffix(".wav")))

    def choose_audio_output():
        path = filedialog.asksaveasfilename(
            title="WAV-Ausgabedatei speichern",
            defaultextension=".wav",
            filetypes=[("WAV PCM Audio", "*.wav"), ("Alle Dateien", "*.*")],
        )
        if path:
            audio_output_var.set(path)

    def choose_ffmpeg():
        path = filedialog.askopenfilename(
            title="Ausführbare FFmpeg-Datei auswählen",
            filetypes=[("FFmpeg", "ffmpeg*"), ("Alle Dateien", "*")],
        )
        if path:
            ffmpeg_var.set(path)

    def set_status(text):
        root.after(0, status_var.set, text)

    def start_conversion():
        if not source_var.get().strip() and not api_var.get().strip():
            messagebox.showerror("Eingabe fehlt", "Gib eine lokale Videodatei, direkte URL oder API-URL an.")
            return
        try:
            width = int(width_var.get())
            height = int(height_var.get())
            fps = float(fps_var.get())
            start = float(start_var.get()) if start_var.get().strip() else None
            duration = float(duration_var.get()) if duration_var.get().strip() else None
            output = Path(output_var.get().strip()).expanduser()
            if not output.name:
                raise ValueError("Bitte ein Ausgabedatei angeben.")
            validate_geometry(width, height, fps)
            if start is not None and start < 0:
                raise ValueError("Start darf nicht negativ sein.")
            if duration is not None and duration <= 0:
                raise ValueError("Dauer muss positiv sein.")
        except (ValueError, OSError) as exc:
            messagebox.showerror("Ungültige Eingabe", str(exc))
            return

        class Args:
            pass
        args = Args()
        args.source_url = source_var.get().strip() or None
        args.api_url = api_var.get().strip() or None
        args.api_token = token_var.get().strip() or None
        args.output = output
        args.audio_output = Path(audio_output_var.get().strip()).expanduser()
        args.width, args.height, args.fps = width, height, fps
        args.start, args.duration = start, duration
        args.ffmpeg = ffmpeg_var.get().strip() or find_ffmpeg()
        frame_total = duration * fps if duration else None
        start_button.configure(state="disabled")
        progress_var.set(0)
        set_status("Konvertierung läuft …")

        def progress(frame_count):
            if frame_total:
                root.after(0, progress_var.set, min(100, frame_count / frame_total * 100))
            root.after(0, status_var.set, f"Frame {frame_count}" + (f" / ca. {int(frame_total)}" if frame_total else ""))

        def worker():
            try:
                result = convert(args, progress_callback=progress)
            except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
                root.after(0, lambda: messagebox.showerror("Konvertierung fehlgeschlagen", str(exc)))
                root.after(0, status_var.set, "Fehler")
            else:
                root.after(0, progress_var.set, 100)
                root.after(0, status_var.set, f"Fertig: {result['frames']} Frames, {result['duration_s']} s")
                root.after(0, lambda: messagebox.showinfo("Fertig", f"BWR1-Datei erstellt:\n{output}\n\nFrames: {result['frames']}\nFPS: {result['fps']}"))
            finally:
                root.after(0, lambda: start_button.configure(state="normal"))

        threading.Thread(target=worker, daemon=True).start()

    frame = ttk.Frame(root, padding=12)
    frame.pack(fill="both", expand=True)
    frame.columnconfigure(1, weight=1)
    ttk.Label(frame, text="Kobo BWR1 Video-Konverter", font=("TkDefaultFont", 15, "bold")).grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 12))
    add_row(frame, 1, "Videodatei oder direkte URL", source_var, choose_source)
    add_row(frame, 2, "Quellen-API (optional)", api_var)
    add_row(frame, 3, "API-Token (optional)", token_var, show="*")
    add_row(frame, 4, "Ausgabedatei (.bwr)", output_var, choose_output)
    add_row(frame, 5, "Audioausgabe (.wav)", audio_output_var, choose_audio_output)
    add_row(frame, 6, "FFmpeg", ffmpeg_var, choose_ffmpeg)

    settings = ttk.LabelFrame(frame, text="Videoeinstellungen", padding=8)
    settings.grid(row=7, column=0, columnspan=3, sticky="ew", pady=12)
    for column in range(6):
        settings.columnconfigure(column, weight=1)
    for column, (label, variable) in enumerate((("Breite", width_var), ("Höhe", height_var), ("FPS", fps_var), ("Start (s)", start_var), ("Dauer (s)", duration_var))):
        ttk.Label(settings, text=label).grid(row=0, column=column, sticky="w", padx=4)
        ttk.Entry(settings, textvariable=variable, width=12).grid(row=1, column=column, sticky="ew", padx=4)

    start_button = ttk.Button(frame, text="Konvertierung starten", command=start_conversion)
    start_button.grid(row=8, column=0, columnspan=3, pady=8)
    ttk.Progressbar(frame, variable=progress_var, maximum=100).grid(row=9, column=0, columnspan=3, sticky="ew", pady=8)
    ttk.Label(frame, textvariable=status_var).grid(row=10, column=0, columnspan=3, sticky="w")
    ttk.Label(frame, text="Die Videoausgabe enthält ausschließlich Schwarz und Weiß. Zusätzlich entsteht eine WAV-Datei für aplay/tinyplay.", wraplength=700).grid(row=11, column=0, columnspan=3, sticky="w", pady=(18, 0))
    root.mainloop()
    return 0


def main() -> int:
    try:
        # No arguments starts the local Tkinter UI. GitHub Actions and scripts
        # that pass arguments continue to use the existing headless mode.
        if len(sys.argv) == 1:
            return run_gui()
        args = parse_args()
        result = convert(args)
        print(json.dumps(result, indent=2))
        return 0
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
