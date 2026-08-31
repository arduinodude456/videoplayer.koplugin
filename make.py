#!/usr/bin/env python3
"""
Build a color-dithered 3-bit video for KOReader E-Ink devices.

BWC1 format:
    header: 32 bytes, little-endian
    frames: 3-bit palette indices, packed MSB first

Palette:
    0 = black
    1 = white
    2 = red
    3 = green
    4 = blue
    5 = yellow
    6 = magenta
    7 = cyan

The converter uses an 8x8 Bayer ordered-dithering matrix.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
from typing import Any
from urllib.request import Request, urlopen

import numpy as np


MAGIC = b"BWC1"
VERSION = 1

# 3-bit indexed color.
PIXEL_FORMAT_COLOR3_MSB = 2

HEADER = struct.Struct("<4sBBHHHII12s")


# ----------------------------------------------------------------------
# Palette
# ----------------------------------------------------------------------

PALETTE = np.array(
    [
        [0,   0,   0],       # 0 black
        [255, 255, 255],     # 1 white
        [255, 0,   0],       # 2 red
        [0,   255, 0],       # 3 green
        [0,   0,   255],     # 4 blue
        [255, 255, 0],       # 5 yellow
        [255, 0,   255],     # 6 magenta
        [0,   255, 255],     # 7 cyan
    ],
    dtype=np.float32,
)


# ----------------------------------------------------------------------
# 8x8 Bayer matrix
# ----------------------------------------------------------------------

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
    dtype=np.float32,
)


def find_ffmpeg() -> str:
    candidates = [
        shutil.which("ffmpeg"),
        "/data/data/com.termux/files/usr/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate

    return "ffmpeg"


def validate_ffmpeg_path(path: str) -> None:
    resolved = shutil.which(path) if "/" not in path else path

    if (
        not resolved
        or not Path(resolved).is_file()
        or not os.access(resolved, os.X_OK)
    ):
        fail(
            "FFmpeg wurde nicht gefunden. "
            "Bitte einen gültigen FFmpeg-Binary-Pfad angeben."
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert video to 3-bit BWC1 color video."
    )

    origin = parser.add_mutually_exclusive_group(required=True)

    origin.add_argument(
        "--source-url",
        help="Direct media URL or local filename.",
    )

    origin.add_argument(
        "--api-url",
        help="Trusted JSON endpoint returning a direct source URL.",
    )

    parser.add_argument(
        "--api-token",
        default=os.getenv("VIDEO_API_TOKEN"),
    )

    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Target .bwc file.",
    )

    parser.add_argument(
        "--audio-output",
        type=Path,
        default=None,
    )

    parser.add_argument(
        "--width",
        type=int,
        default=1264,
    )

    parser.add_argument(
        "--height",
        type=int,
        default=1680,
    )

    parser.add_argument(
        "--fps",
        type=float,
        default=12.0,
    )

    parser.add_argument(
        "--start",
        type=float,
        default=None,
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=None,
    )

    parser.add_argument(
        "--ffmpeg",
        default="ffmpeg",
    )

    return parser.parse_args()


def fail(message: str) -> None:
    raise RuntimeError(message)


# ----------------------------------------------------------------------
# Geometry
# ----------------------------------------------------------------------

def validate_geometry(
    width: int,
    height: int,
    fps: float,
) -> None:

    if not (1 <= width <= 4096 and 1 <= height <= 4096):
        fail("Width and height must be between 1 and 4096.")

    if width % 8 != 0:
        fail(
            "Width must be divisible by 8 "
            "because 8 pixels are packed into 3 bytes."
        )

    if not (0.01 <= fps <= 30.0):
        fail("FPS must be between 0.01 and 30.00.")


# ----------------------------------------------------------------------
# API
# ----------------------------------------------------------------------

def resolve_api(
    api_url: str,
    token: str | None,
) -> tuple[str, dict[str, Any]]:

    headers = {
        "Accept": "application/json",
        "User-Agent": "kobo-color-video/1",
    }

    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = Request(
        api_url,
        headers=headers,
        method="GET",
    )

    with urlopen(request, timeout=30) as response:
        charset = (
            response.headers.get_content_charset()
            or "utf-8"
        )

        payload = json.loads(
            response.read().decode(charset)
        )

    if not isinstance(payload, dict):
        fail("The API response must be a JSON object.")

    source_url = (
        payload.get("source_url")
        or payload.get("url")
        or payload.get("source")
    )

    if not isinstance(source_url, str) or not source_url:
        fail(
            "The API response needs source_url, "
            "url, or source."
        )

    return source_url, payload


# ----------------------------------------------------------------------
# FFmpeg
# ----------------------------------------------------------------------

def make_filter(
    width: int,
    height: int,
    fps: float,
) -> str:

    return (
        f"fps=fps={fps:g},"
        f"scale={width}:{height}:"
        f"force_original_aspect_ratio=decrease:"
        f"flags=lanczos,"
        f"pad={width}:{height}:"
        f"(ow-iw)/2:(oh-ih)/2:"
        f"color=black,"
        f"format=rgb24"
    )


def ffmpeg_command(
    args: argparse.Namespace,
    source: str,
    start: float | None,
    duration: float | None,
    audio_output: Path,
) -> list[str]:

    command = [
        args.ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
    ]

    if start is not None:
        if start < 0:
            fail("Start must not be negative.")

        command.extend([
            "-ss",
            f"{start:.3f}",
        ])

    command.extend([
        "-i",
        source,
    ])

    if duration is not None:
        if duration <= 0:
            fail("Duration must be positive.")

        command.extend([
            "-t",
            f"{duration:.3f}",
        ])

    command.extend([
        "-an",
        "-sn",
        "-dn",

        "-vf",
        make_filter(
            args.width,
            args.height,
            args.fps,
        ),

        "-pix_fmt",
        "rgb24",

        "-f",
        "rawvideo",

        "pipe:1",

        "-map",
        "0:a:0?",
        "-vn",
        "-c:a",
        "pcm_s16le",
        "-ar",
        "44100",
        "-ac",
        "2",
        "-f",
        "wav",
        str(audio_output),
    ])

    return command


# ----------------------------------------------------------------------
# Color dithering
# ----------------------------------------------------------------------

def dither_color_frame(
    frame: bytes,
    width: int,
    height: int,
) -> bytes:

    rgb = np.frombuffer(
        frame,
        dtype=np.uint8,
    ).reshape(
        (height, width, 3)
    ).astype(
        np.float32
    )

    thresholds = np.tile(
        BAYER_8,
        (
            math.ceil(height / 8),
            math.ceil(width / 8),
        ),
    )[:height, :width]

    # Convert 0..63 Bayer value to approximately -2..+2
    # around the original RGB value.
    #
    # The perturbation is deliberately relatively strong:
    # the target display only has eight colors.
    dither = (
        (thresholds / 63.0) - 0.5
    ) * 64.0

    dither = dither[:, :, None]

    adjusted = np.clip(
        rgb + dither,
        0,
        255,
    )

    # Squared Euclidean distance to each of the 8 palette colors.
    #
    # Shape:
    #   pixels x colors
    diff = (
        adjusted[:, :, None, :]
        - PALETTE[None, None, :, :]
    )

    distance = np.sum(
        diff * diff,
        axis=3,
    )

    indices = np.argmin(
        distance,
        axis=2,
    ).astype(
        np.uint8
    )

    return pack_3bit(indices)


# ----------------------------------------------------------------------
# 3-bit packing
#
# Eight pixels = 24 bits = 3 bytes.
#
# Pixel order:
#
#   p0 p1 p2 p3 p4 p5 p6 p7
#
# Byte 0:
#   p0 bits 7..5
#   p1 bits 4..2
#   p2 bits 1..0
#
# Byte 1:
#   p2 bit 2
#   p3 bits 7..5
#   p4 bits 4..2
#   p5 bits 1..0
#
# Byte 2:
#   p5 bit 2
#   p6 bits 7..5
#   p7 bits 4..2
# ----------------------------------------------------------------------

def pack_3bit(indices: np.ndarray) -> bytes:

    flat = indices.reshape(-1)

    if len(flat) % 8 != 0:
        raise ValueError(
            "Number of pixels must be divisible by 8."
        )

    p = flat.reshape(-1, 8).astype(np.uint8)

    b0 = (
        (p[:, 0] << 5)
        | (p[:, 1] << 2)
        | (p[:, 2] >> 1)
    )

    b1 = (
        ((p[:, 2] & 0x01) << 7)
        | (p[:, 3] << 4)
        | (p[:, 4] << 1)
        | (p[:, 5] >> 2)
    )

    b2 = (
        ((p[:, 5] & 0x03) << 6)
        | (p[:, 6] << 3)
        | p[:, 7]
    )

    output = np.empty(
        len(p) * 3,
        dtype=np.uint8,
    )

    output[0::3] = b0
    output[1::3] = b1
    output[2::3] = b2

    return output.tobytes()


# ----------------------------------------------------------------------
# Conversion
# ----------------------------------------------------------------------

def convert(
    args: argparse.Namespace,
    progress_callback=None,
) -> dict[str, Any]:

    validate_geometry(
        args.width,
        args.height,
        args.fps,
    )

    validate_ffmpeg_path(
        args.ffmpeg
    )

    source = args.source_url

    api_payload: dict[str, Any] = {}

    if args.api_url:
        source, api_payload = resolve_api(
            args.api_url,
            args.api_token,
        )

    start = (
        args.start
        if args.start is not None
        else api_payload.get("start_s")
    )

    duration = (
        args.duration
        if args.duration is not None
        else api_payload.get("duration_s")
    )

    start = (
        float(start)
        if start is not None
        else None
    )

    duration = (
        float(duration)
        if duration is not None
        else None
    )

    frame_input_bytes = (
        args.width
        * args.height
        * 3
    )

    frame_output_bytes = (
        args.width
        * args.height
        * 3
        // 8
    )

    audio_output = (
        args.audio_output
        or args.output.with_suffix(".wav")
    )

    args.output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    audio_output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary = Path(
        tempfile.mkstemp(
            prefix="kobo-bwc-",
            suffix=".partial",
        )[1]
    )

    temporary.unlink(
        missing_ok=True
    )

    audio_temporary = Path(
        tempfile.mkstemp(
            prefix="kobo-audio-",
            suffix=".wav.partial",
        )[1]
    )

    audio_temporary.unlink(
        missing_ok=True
    )

    command = ffmpeg_command(
        args,
        source,
        start,
        duration,
        audio_temporary,
    )

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    frame_count = 0

    try:
        with temporary.open("wb") as out:

            # Placeholder header.
            out.write(
                HEADER.pack(
                    MAGIC,
                    VERSION,
                    PIXEL_FORMAT_COLOR3_MSB,
                    args.width,
                    args.height,
                    round(args.fps * 100),
                    0,
                    frame_output_bytes,
                    b"\0" * 12,
                )
            )

            assert process.stdout is not None

            while True:

                frame = process.stdout.read(
                    frame_input_bytes
                )

                if not frame:
                    break

                if len(frame) != frame_input_bytes:
                    fail(
                        "FFmpeg produced an incomplete "
                        "raw RGB frame."
                    )

                packed = dither_color_frame(
                    frame,
                    args.width,
                    args.height,
                )

                out.write(packed)

                frame_count += 1

                if progress_callback:
                    progress_callback(
                        frame_count
                    )

    finally:

        if process.stdout:
            process.stdout.close()

    stderr = (
        process.stderr.read()
        .decode(
            "utf-8",
            errors="replace",
        )
        if process.stderr
        else ""
    )

    return_code = process.wait()

    if return_code != 0:
        temporary.unlink(
            missing_ok=True
        )

        fail(
            "FFmpeg failed: "
            + (
                stderr.strip()
                or f"exit status {return_code}"
            )
        )

    if frame_count == 0:

        temporary.unlink(
            missing_ok=True
        )

        audio_temporary.unlink(
            missing_ok=True
        )

        fail(
            "The source produced no video frames."
        )

    if (
        not audio_temporary.exists()
        or audio_temporary.stat().st_size <= 44
    ):

        temporary.unlink(
            missing_ok=True
        )

        audio_temporary.unlink(
            missing_ok=True
        )

        fail(
            "The source contains no audio track "
            "that FFmpeg could export as WAV."
        )

    # Rewrite header with actual frame count.
    with temporary.open("r+b") as out:

        out.write(
            HEADER.pack(
                MAGIC,
                VERSION,
                PIXEL_FORMAT_COLOR3_MSB,
                args.width,
                args.height,
                round(args.fps * 100),
                frame_count,
                frame_output_bytes,
                b"\0" * 12,
            )
        )

    try:

        shutil.copyfile(
            temporary,
            args.output,
        )

    except OSError as exc:

        temporary.unlink(
            missing_ok=True
        )

        fail(
            f"Cannot write output file: {exc}"
        )

    temporary.unlink(
        missing_ok=True
    )

    try:

        shutil.copyfile(
            audio_temporary,
            audio_output,
        )

    except OSError as exc:

        audio_temporary.unlink(
            missing_ok=True
        )

        fail(
            f"Cannot write WAV file: {exc}"
        )

    audio_temporary.unlink(
        missing_ok=True
    )

    metadata = {
        "format": "BWC1",
        "version": VERSION,
        "pixel_format": "color3-msb",
        "palette": [
            "#000000",
            "#FFFFFF",
            "#FF0000",
            "#00FF00",
            "#0000FF",
            "#FFFF00",
            "#FF00FF",
            "#00FFFF",
        ],
        "width": args.width,
        "height": args.height,
        "fps": args.fps,
        "frames": frame_count,
        "duration_s": round(
            frame_count / args.fps,
            3,
        ),
        "frame_bytes": frame_output_bytes,
        "source_title": api_payload.get("title"),
        "source_id": api_payload.get("id"),
        "audio_format": "WAV PCM s16le, 44100 Hz, stereo",
        "audio_file": str(audio_output),
    }

    metadata_path = args.output.with_suffix(
        args.output.suffix + ".json"
    )

    metadata_path.write_text(
        json.dumps(
            metadata,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    return metadata


# ----------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------

def run_gui() -> int:

    import threading
    import tkinter as tk
    from tkinter import filedialog
    from tkinter import messagebox
    from tkinter import ttk

    root = tk.Tk()

    root.title(
        "Kobo BWC1 Color Video-Konverter"
    )

    root.geometry(
        "760x560"
    )

    root.minsize(
        650,
        500,
    )

    source_var = tk.StringVar()
    api_var = tk.StringVar()
    token_var = tk.StringVar()

    output_var = tk.StringVar(
        value=str(
            Path.cwd()
            / "video.bwc"
        )
    )

    audio_output_var = tk.StringVar(
        value=str(
            Path.cwd()
            / "video.wav"
        )
    )

    ffmpeg_var = tk.StringVar(
        value=find_ffmpeg()
    )

    width_var = tk.StringVar(
        value="1264"
    )

    height_var = tk.StringVar(
        value="1680"
    )

    fps_var = tk.StringVar(
        value="12"
    )

    start_var = tk.StringVar()

    duration_var = tk.StringVar(
        value="30"
    )

    status_var = tk.StringVar(
        value="Bereit"
    )

    progress_var = tk.DoubleVar(
        value=0
    )

    def add_row(
        parent,
        row,
        label,
        variable,
        browse_command=None,
        show=None,
    ):

        ttk.Label(
            parent,
            text=label,
        ).grid(
            row=row,
            column=0,
            sticky="w",
            padx=6,
            pady=5,
        )

        entry = ttk.Entry(
            parent,
            textvariable=variable,
            show=show or "",
        )

        entry.grid(
            row=row,
            column=1,
            sticky="ew",
            padx=6,
            pady=5,
        )

        if browse_command:

            ttk.Button(
                parent,
                text="Auswählen",
                command=browse_command,
            ).grid(
                row=row,
                column=2,
                padx=6,
                pady=5,
            )

        return entry

    def choose_source():

        path = filedialog.askopenfilename(
            title="Videodatei auswählen",
            filetypes=[
                (
                    "Video",
                    "*.mp4 *.mkv *.webm *.mov *.avi",
                ),
                (
                    "Alle Dateien",
                    "*.*",
                ),
            ],
        )

        if path:
            source_var.set(path)

    def choose_output():

        path = filedialog.asksaveasfilename(
            title="BWC1-Ausgabedatei speichern",
            defaultextension=".bwc",
            filetypes=[
                (
                    "BWC1 Color RAW Video",
                    "*.bwc",
                ),
                (
                    "Alle Dateien",
                    "*.*",
                ),
            ],
        )

        if path:

            output_var.set(path)

            audio_output_var.set(
                str(
                    Path(path).with_suffix(
                        ".wav"
                    )
                )
            )

    def choose_audio_output():

        path = filedialog.asksaveasfilename(
            title="WAV-Ausgabedatei speichern",
            defaultextension=".wav",
            filetypes=[
                (
                    "WAV PCM Audio",
                    "*.wav",
                ),
                (
                    "Alle Dateien",
                    "*.*",
                ),
            ],
        )

        if path:
            audio_output_var.set(path)

    def choose_ffmpeg():

        path = filedialog.askopenfilename(
            title="Ausführbare FFmpeg-Datei auswählen",
            filetypes=[
                (
                    "FFmpeg",
                    "ffmpeg*",
                ),
                (
                    "Alle Dateien",
                    "*",
                ),
            ],
        )

        if path:
            ffmpeg_var.set(path)

    def set_status(text):

        root.after(
            0,
            status_var.set,
            text,
        )

    def start_conversion():

        if (
            not source_var.get().strip()
            and not api_var.get().strip()
        ):

            messagebox.showerror(
                "Eingabe fehlt",
                "Gib eine lokale Videodatei, "
                "direkte URL oder API-URL an.",
            )

            return

        try:

            width = int(
                width_var.get()
            )

            height = int(
                height_var.get()
            )

            fps = float(
                fps_var.get()
            )

            start = (
                float(start_var.get())
                if start_var.get().strip()
                else None
            )

            duration = (
                float(duration_var.get())
                if duration_var.get().strip()
                else None
            )

            output = Path(
                output_var.get().strip()
            ).expanduser()

            validate_geometry(
                width,
                height,
                fps,
            )

            if start is not None and start < 0:
                raise ValueError(
                    "Start darf nicht negativ sein."
                )

            if (
                duration is not None
                and duration <= 0
            ):
                raise ValueError(
                    "Dauer muss positiv sein."
                )

        except (
            ValueError,
            OSError,
        ) as exc:

            messagebox.showerror(
                "Ungültige Eingabe",
                str(exc),
            )

            return

        class Args:
            pass

        args = Args()

        args.source_url = (
            source_var.get().strip()
            or None
        )

        args.api_url = (
            api_var.get().strip()
            or None
        )

        args.api_token = (
            token_var.get().strip()
            or None
        )

        args.output = output

        args.audio_output = Path(
            audio_output_var.get().strip()
        ).expanduser()

        args.width = width
        args.height = height
        args.fps = fps

        args.start = start
        args.duration = duration

        args.ffmpeg = (
            ffmpeg_var.get().strip()
            or find_ffmpeg()
        )

        frame_total = (
            duration * fps
            if duration
            else None
        )

        start_button.configure(
            state="disabled"
        )

        progress_var.set(0)

        set_status(
            "Farbkonvertierung läuft …"
        )

        def progress(frame_count):

            if frame_total:

                root.after(
                    0,
                    progress_var.set,
                    min(
                        100,
                        frame_count
                        / frame_total
                        * 100,
                    ),
                )

            root.after(
                0,
                status_var.set,
                f"Frame {frame_count}"
                + (
                    f" / ca. {int(frame_total)}"
                    if frame_total
                    else ""
                ),
            )

        def worker():

            try:

                result = convert(
                    args,
                    progress_callback=progress,
                )

            except (
                RuntimeError,
                OSError,
                subprocess.SubprocessError,
                ValueError,
                json.JSONDecodeError,
            ) as exc:

                root.after(
                    0,
                    lambda: messagebox.showerror(
                        "Konvertierung fehlgeschlagen",
                        str(exc),
                    ),
                )

                root.after(
                    0,
                    status_var.set,
                    "Fehler",
                )

            else:

                root.after(
                    0,
                    progress_var.set,
                    100,
                )

                root.after(
                    0,
                    status_var.set,
                    (
                        f"Fertig: "
                        f"{result['frames']} Frames, "
                        f"{result['duration_s']} s"
                    ),
                )

                root.after(
                    0,
                    lambda: messagebox.showinfo(
                        "Fertig",
                        (
                            f"BWC1-Datei erstellt:\n"
                            f"{output}\n\n"
                            f"Frames: {result['frames']}\n"
                            f"FPS: {result['fps']}"
                        ),
                    ),
                )

            finally:

                root.after(
                    0,
                    lambda: start_button.configure(
                        state="normal"
                    ),
                )

        threading.Thread(
            target=worker,
            daemon=True,
        ).start()

    frame = ttk.Frame(
        root,
        padding=12,
    )

    frame.pack(
        fill="both",
        expand=True,
    )

    frame.columnconfigure(
        1,
        weight=1,
    )

    ttk.Label(
        frame,
        text="Kobo BWC1 Color Video-Konverter",
        font=(
            "TkDefaultFont",
            15,
            "bold",
        ),
    ).grid(
        row=0,
        column=0,
        columnspan=3,
        sticky="w",
        pady=(0, 12),
    )

    add_row(
        frame,
        1,
        "Video:",
        source_var,
        choose_source,
    )

    add_row(
        frame,
        2,
        "API-URL:",
        api_var,
    )

    add_row(
        frame,
        3,
        "API-Token:",
        token_var,
        show="*",
    )

    add_row(
        frame,
        4,
        "Ausgabe:",
        output_var,
        choose_output,
    )

    add_row(
        frame,
        5,
        "Audio:",
        audio_output_var,
        choose_audio_output,
    )

    add_row(
        frame,
        6,
        "FFmpeg:",
        ffmpeg_var,
        choose_ffmpeg,
    )

    add_row(
        frame,
        7,
        "Breite:",
        width_var,
    )

    add_row(
        frame,
        8,
        "Höhe:",
        height_var,
    )

    add_row(
        frame,
        9,
        "FPS:",
        fps_var,
    )

    add_row(
        frame,
        10,
        "Start:",
        start_var,
    )

    add_row(
        frame,
        11,
        "Dauer:",
        duration_var,
    )

    ttk.Label(
        frame,
        text=(
            "Palette: Schwarz, Weiß, Rot, Grün, "
            "Blau, Gelb, Magenta, Cyan\n"
            "Dithering: 8x8 Bayer"
        ),
    ).grid(
        row=12,
        column=0,
        columnspan=3,
        sticky="w",
        pady=(12, 4),
    )

    progress = ttk.Progressbar(
        frame,
        variable=progress_var,
        maximum=100,
    )

    progress.grid(
        row=13,
        column=0,
        columnspan=3,
        sticky="ew",
        padx=6,
        pady=8,
    )

    ttk.Label(
        frame,
        textvariable=status_var,
    ).grid(
        row=14,
        column=0,
        columnspan=3,
        sticky="w",
        padx=6,
        pady=4,
    )

    start_button = ttk.Button(
        frame,
        text="Farbvideo erstellen",
        command=start_conversion,
    )

    start_button.grid(
        row=15,
        column=0,
        columnspan=3,
        pady=12,
    )

    root.mainloop()

    return 0


if __name__ == "__main__":
    raise SystemExit(
        run_gui()
    )