#!/usr/bin/env python3
"""Build the bundled assistant-pet sprite strips from pinned upstream assets."""

from __future__ import annotations

import io
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "tmp" / "pet_sources"
OUTPUT = ROOT / "assets" / "pets"

MOOMEW_COMMIT = "66215311b74a2b8816ff250b0ba35126b468d303"
XIAOHEI_COMMIT = "94d7eb55b85dcf10e47ad002d0417d0fb4d91436"
WHALE_COMMIT = "267e64fa61e6429bdd7cc06bf32cc53e559ff71c"

MOOMEW_DURATIONS = {
    "idle": [280, 110, 110, 140, 140, 320],
    "running-right": [120, 120, 120, 120, 120, 120, 120, 220],
    "running-left": [120, 120, 120, 120, 120, 120, 120, 220],
    "waving": [140, 140, 140, 280],
    "jumping": [140, 140, 140, 140, 280],
    "failed": [140, 140, 140, 140, 140, 140, 140, 240],
    "waiting": [150, 150, 150, 150, 150, 260],
    "review": [150, 150, 150, 150, 150, 280],
}

WHALE_STATES = (
    "idle",
    "working",
    "celebrate",
    "error",
    "disappointed",
    "joy",
    "drag",
    "sleep",
    "wake",
    "welcome",
    "think",
    "wait",
)

XIAOHEI_FILES = {
    "idle": "shake-head-txt.gif",
    "guitar": "playing guitar.gif",
    "groom": "licking the claw.gif",
    "bye": "bye.gif",
    "play": "play heixiu.gif",
    "eat": "eat drumstick.gif",
}


def raw_url(repo: str, commit: str, path: str) -> str:
    encoded = urllib.parse.quote(path, safe="/")
    return f"https://raw.githubusercontent.com/{repo}/{commit}/{encoded}"


def download(url: str, cache_path: Path) -> bytes:
    if cache_path.exists():
        return cache_path.read_bytes()
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "music-player-app"})
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = response.read()
    cache_path.write_bytes(payload)
    return payload


def normalize_frame(frame: Image.Image, side: int = 256) -> Image.Image:
    """Put a source frame on a stable square stage without cropping it."""
    frame = frame.convert("RGBA")
    scale = min((side - 20) / frame.width, (side - 20) / frame.height)
    width = max(1, round(frame.width * scale))
    height = max(1, round(frame.height * scale))
    resized = frame.resize((width, height), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(resized, ((side - width) // 2, side - height - 6))
    return canvas


def save_strip(frames: list[Image.Image], output: Path) -> None:
    if not frames:
        raise ValueError(f"No frames for {output}")
    frames = [normalize_frame(frame) for frame in frames]
    width, height = frames[0].size
    if any(frame.size != (width, height) for frame in frames):
        raise ValueError(f"Mismatched frame sizes for {output}")
    strip = Image.new("RGBA", (width * len(frames), height), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        strip.alpha_composite(frame.convert("RGBA"), (index * width, 0))
    output.parent.mkdir(parents=True, exist_ok=True)
    strip.save(
        output,
        format="WEBP",
        lossless=True,
        method=6,
        exact=True,
    )


def build_moomew() -> None:
    source = download(
        raw_url(
            "legeling/awesome-codex-pet",
            MOOMEW_COMMIT,
            "pets/moomew-coder-cat--ping/spritesheet.webp",
        ),
        CACHE / "moomew-spritesheet.webp",
    )
    with Image.open(io.BytesIO(source)) as opened:
        atlas = opened.convert("RGBA")
    if atlas.size != (1536, 1872):
        raise ValueError(f"Unexpected MooMew atlas size: {atlas.size}")
    cell_width, cell_height = 192, 208
    row_by_state = {
        "idle": 0,
        "running-right": 1,
        "running-left": 2,
        "waving": 3,
        "jumping": 4,
        "failed": 5,
        "waiting": 6,
        "review": 8,
    }
    for state, durations in MOOMEW_DURATIONS.items():
        row = row_by_state[state]
        frames = [
            atlas.crop(
                (
                    column * cell_width,
                    row * cell_height,
                    (column + 1) * cell_width,
                    (row + 1) * cell_height,
                )
            )
            for column in range(len(durations))
        ]
        save_strip(frames, OUTPUT / "moomew" / f"{state}.webp")


def build_xiaohei() -> None:
    for state, filename in XIAOHEI_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{state}.gif",
        )
        frames: list[Image.Image] = []
        with Image.open(io.BytesIO(source)) as opened:
            for index in range(opened.n_frames):
                opened.seek(index)
                frames.append(opened.convert("RGBA"))
        save_strip(frames, OUTPUT / "xiaohei" / f"{state}.webp")


def build_whale() -> None:
    for state in WHALE_STATES:
        source = download(
            raw_url(
                "vlln/whale-girl",
                WHALE_COMMIT,
                f"lib/assets/characters/whale-girl/{state}.png",
            ),
            CACHE / "whale-girl" / f"{state}.png",
        )
        with Image.open(io.BytesIO(source)) as opened:
            strip = opened.convert("RGBA")
        output = OUTPUT / "whale_girl" / f"{state}.webp"
        output.parent.mkdir(parents=True, exist_ok=True)
        strip.save(output, format="WEBP", lossless=True, method=6, exact=True)


def main() -> None:
    build_moomew()
    build_xiaohei()
    build_whale()
    for output in sorted(OUTPUT.rglob("*.webp")):
        print(f"{output.relative_to(ROOT)}\t{output.stat().st_size}")


if __name__ == "__main__":
    main()
