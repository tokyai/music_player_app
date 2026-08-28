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

# Every strip is placed on the same 256 px stage.  A common visible-height
# target keeps a pose change from looking like a zoom, while the union box per
# strip preserves the source animation's relative movement between frames.
PET_STAGE = 256
PET_TARGET_HEIGHT = 200
PET_BASELINE = 250
PET_EDGE_ALPHA_CUTOFF = 8

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


def normalize_frames(frames: list[Image.Image]) -> list[Image.Image]:
    """Put a strip on one stable stage and align every frame to its baseline.

    The scale is calculated once from the strip's union alpha bounds rather
    than independently per frame.  That avoids an artificial zoom when a
    character changes pose, while the fixed baseline prevents the feet from
    hopping when switching between actions.
    """
    if not frames:
        raise ValueError("No frames to normalize")
    rgba_frames = [frame.convert("RGBA") for frame in frames]
    boxes = [frame.getchannel("A").getbbox() for frame in rgba_frames]
    if any(box is None for box in boxes):
        raise ValueError("A pet frame has no visible pixels")
    left = min(box[0] for box in boxes if box is not None)
    top = min(box[1] for box in boxes if box is not None)
    right = max(box[2] for box in boxes if box is not None)
    bottom = max(box[3] for box in boxes if box is not None)
    union_width = right - left
    union_height = bottom - top
    scale = min(
        PET_TARGET_HEIGHT / union_height,
        (PET_STAGE - 12) / union_width,
    )
    normalized: list[Image.Image] = []
    for frame in rgba_frames:
        width = max(1, round(frame.width * scale))
        height = max(1, round(frame.height * scale))
        resized = frame.resize((width, height), Image.Resampling.LANCZOS)
        alpha = resized.getchannel("A").point(
            lambda value: 0 if value < PET_EDGE_ALPHA_CUTOFF else value
        )
        resized.putalpha(alpha)
        canvas = Image.new(
            "RGBA", (PET_STAGE, PET_STAGE), (0, 0, 0, 0)
        )
        resized_box = resized.getchannel("A").getbbox()
        assert resized_box is not None
        visible_center = (resized_box[0] + resized_box[2]) / 2
        x = round(PET_STAGE / 2 - visible_center)
        y = PET_BASELINE - resized_box[3]
        # alpha_composite clips gracefully at the stage edge and preserves the
        # source alpha instead of multiplying antialiased edge pixels twice.
        canvas.alpha_composite(resized, dest=(x, y))
        normalized.append(canvas)
    return normalized


def save_strip(frames: list[Image.Image], output: Path) -> None:
    if not frames:
        raise ValueError(f"No frames for {output}")
    frames = normalize_frames(frames)
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

    idle_row = 0
    idle_frames = [
        atlas.crop(
            (
                column * cell_width,
                idle_row * cell_height,
                (column + 1) * cell_width,
                (idle_row + 1) * cell_height,
            )
        )
        for column in range(6)
    ]
    save_strip([idle_frames[0]], OUTPUT / "moomew" / "rest.webp")
    save_strip(
        [idle_frames[index] for index in (0, 2, 0)],
        OUTPUT / "moomew" / "idle-blink.webp",
    )
    save_strip(
        [idle_frames[index] for index in (0, 1, 0)],
        OUTPUT / "moomew" / "idle-glance.webp",
    )


def build_xiaohei() -> None:
    idle_frames: list[Image.Image] = []
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
        if state == "idle":
            idle_frames = frames
    if not idle_frames:
        raise ValueError("Missing Xiaohei idle frames")
    save_strip([idle_frames[0]], OUTPUT / "xiaohei" / "rest.webp")
    save_strip(
        [idle_frames[index] for index in (0, 1, 0)],
        OUTPUT / "xiaohei" / "idle-glance.webp",
    )
    save_strip(
        [idle_frames[index] for index in (0, 8, 0)],
        OUTPUT / "xiaohei" / "idle-tilt.webp",
    )


def build_whale() -> None:
    idle_frames: list[Image.Image] = []
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
        frames = [
            strip.crop(
                (column * PET_STAGE, 0, (column + 1) * PET_STAGE, PET_STAGE)
            )
            for column in range(strip.width // PET_STAGE)
        ]
        output = OUTPUT / "whale_girl" / f"{state}.webp"
        save_strip(frames, output)
        if state == "idle":
            idle_frames = frames
    if not idle_frames:
        raise ValueError("Missing Whale Girl idle frames")
    save_strip([idle_frames[0]], OUTPUT / "whale_girl" / "rest.webp")
    save_strip(
        [idle_frames[index] for index in (0, 1, 0)],
        OUTPUT / "whale_girl" / "idle-blink.webp",
    )


def main() -> None:
    build_moomew()
    build_xiaohei()
    build_whale()
    for output in sorted(OUTPUT.rglob("*.webp")):
        print(f"{output.relative_to(ROOT)}\t{output.stat().st_size}")


if __name__ == "__main__":
    main()
