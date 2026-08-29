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
XIAOHEI_LOUNGE_COMMIT = "157709812463a28f7fc2145f2e5dffab11a89395"
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
    # The source row is a complete yarn-ball interaction.  It is kept as a
    # rare idle companion action rather than a continuous state animation.
    "yarn": [180, 120, 120, 160, 260, 420],
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
    "play": "play heixiu.gif",
    "error-shake": "shake-head-txt.gif",
}

XIAOHEI_EXTRA_FILES = {
    "eat-watermelon": "eat-watermelon-txt.gif",
}

XIAOHEI_EFFECT_FILES = {
    "cloud": "smiling clouds.png",
    "sun": "emotion increasing animation.png",
}

XIAOHEI_LOUNGE_FILES = {
    "lounge": "pet1/罗小黑w0.gif",
    "lounge-awake": "pet1/罗小黑11.gif",
    "lounge-curious": "pet1/罗小黑0.gif",
    "lounge-stretch": "pet1/罗小黑4.gif",
    "groom": "pet1/init/start.gif",
    "guitar": "pet1/罗小黑5.gif",
    "eat-burger": "pet1/罗小黑9.gif",
    "walk": "pet1/罗小黑w1.gif",
}

# These sources include detached thought bubbles, a small duplicate pet or a
# dangling ball. They work in the desktop-pet scene but read as visual debris
# in the assistant slot, so only the main connected character is retained.
XIAOHEI_KEEP_MAIN_COMPONENT = {
    "lounge-awake",
    "lounge-curious",
    "lounge-stretch",
    "guitar",
}

XIAOHEI_FRAME_SELECTIONS = {
    # 44 source frames would create an 11264 px texture, beyond the 8192 px
    # limit on some Android GPUs. Even sampling preserves the full action and
    # original 4.4 second duration in a 5632 px strip.
    "eat-burger": [*range(0, 42, 2), 43],
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


def save_stage_strip(frames: list[Image.Image], output: Path) -> None:
    """Save already aligned 256px stages without re-centering their effects."""
    if not frames:
        raise ValueError(f"No frames for {output}")
    width, height = frames[0].size
    if (width, height) != (PET_STAGE, PET_STAGE):
        raise ValueError(f"Expected {PET_STAGE}px stages for {output}")
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


def _crop_visible(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    box = rgba.getchannel("A").getbbox()
    if box is None:
        raise ValueError("Effect image has no visible pixels")
    return rgba.crop(box)


def _scaled_alpha(image: Image.Image, alpha: float) -> Image.Image:
    if alpha >= 0.999:
        return image
    result = image.copy()
    channel = result.getchannel("A").point(
        lambda value: round(value * max(0.0, min(1.0, alpha)))
    )
    result.putalpha(channel)
    return result


def _keep_largest_alpha_component(image: Image.Image) -> Image.Image:
    """Remove detached props while preserving the main connected drawing."""
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    width, height = rgba.size
    visible = alpha.load()
    visited = bytearray(width * height)
    largest: list[tuple[int, int]] = []

    for start_y in range(height):
        for start_x in range(width):
            start_index = start_y * width + start_x
            if visited[start_index] or visible[start_x, start_y] == 0:
                continue
            component: list[tuple[int, int]] = []
            stack = [(start_x, start_y)]
            visited[start_index] = 1
            while stack:
                x, y = stack.pop()
                component.append((x, y))
                for next_x, next_y in (
                    (x - 1, y),
                    (x + 1, y),
                    (x, y - 1),
                    (x, y + 1),
                ):
                    if not (0 <= next_x < width and 0 <= next_y < height):
                        continue
                    next_index = next_y * width + next_x
                    if visited[next_index] or visible[next_x, next_y] == 0:
                        continue
                    visited[next_index] = 1
                    stack.append((next_x, next_y))
            if len(component) > len(largest):
                largest = component

    if not largest:
        raise ValueError("A pet frame has no visible pixels")
    mask = Image.new("L", rgba.size, 0)
    mask_pixels = mask.load()
    for x, y in largest:
        mask_pixels[x, y] = visible[x, y]
    rgba.putalpha(mask)
    return rgba


def _load_gif_frames(payload: bytes) -> list[Image.Image]:
    frames: list[Image.Image] = []
    with Image.open(io.BytesIO(payload)) as opened:
        for index in range(opened.n_frames):
            opened.seek(index)
            frames.append(opened.convert("RGBA"))
    return frames


def make_xiaohei_effect_strip(
    base: Image.Image,
    effect: Image.Image,
    *,
    target_width: int,
    right: int,
    top: int,
    output: Path,
) -> None:
    """Compose a small, fading idle effect onto XiaoHei's neutral pose."""
    cropped = _crop_visible(effect)
    scale = target_width / cropped.width
    effect_size = (
        max(1, round(cropped.width * scale)),
        max(1, round(cropped.height * scale)),
    )
    resized = cropped.resize(effect_size, Image.Resampling.LANCZOS)
    x = right - resized.width
    # The slight vertical movement gives static source artwork a quiet
    # entrance/exit without introducing a separate runtime overlay layer.
    frames: list[Image.Image] = []
    for alpha, offset_y, offset_x in (
        (0.0, 4, 0),
        (0.52, 2, -1),
        (1.0, 0, 0),
        (0.72, -1, 1),
        (0.0, -2, 1),
    ):
        frame = base.copy()
        frame.alpha_composite(
            _scaled_alpha(resized, alpha),
            dest=(x + offset_x, top + offset_y),
        )
        frames.append(frame)
    save_stage_strip(frames, output)


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
        "yarn": 7,
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
    for state, filename in XIAOHEI_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{state}.gif",
        )
        frames = _load_gif_frames(source)
        save_strip(frames, OUTPUT / "xiaohei" / f"{state}.webp")

    for state, filename in XIAOHEI_EXTRA_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{state}.gif",
        )
        frames = _load_gif_frames(source)
        save_strip(frames, OUTPUT / "xiaohei" / f"{state}.webp")

    lounge_frames: dict[str, list[Image.Image]] = {}
    for state, path in XIAOHEI_LOUNGE_FILES.items():
        source = download(
            raw_url(
                "winterqin/DesktopPet_Winter_luoxiaohei",
                XIAOHEI_LOUNGE_COMMIT,
                path,
            ),
            CACHE / "xiaohei-lounge-set" / f"{state}.gif",
        )
        frames = _load_gif_frames(source)
        if state in XIAOHEI_KEEP_MAIN_COMPONENT:
            frames = [_keep_largest_alpha_component(frame) for frame in frames]
        selection = XIAOHEI_FRAME_SELECTIONS.get(state)
        if selection is not None:
            frames = [frames[index] for index in selection]
        lounge_frames[state] = frames

    normalized_lounge = normalize_frames(lounge_frames["lounge"])
    save_stage_strip(normalized_lounge, OUTPUT / "xiaohei" / "lounge.webp")
    save_stage_strip(
        [normalized_lounge[7]], OUTPUT / "xiaohei" / "rest.webp"
    )
    save_stage_strip(
        [normalized_lounge[index] for index in (7, 6, 7)],
        OUTPUT / "xiaohei" / "idle-tail-flick.webp",
    )
    save_stage_strip(
        [normalized_lounge[index] for index in (7, 8, 9, 8, 7)],
        OUTPUT / "xiaohei" / "idle-settle.webp",
    )
    for state, frames in lounge_frames.items():
        if state == "lounge":
            continue
        save_strip(frames, OUTPUT / "xiaohei" / f"{state}.webp")

    # Cloud and sun are decorative source images, not replacement poses.  We
    # bake them onto the relaxed XiaoHei stage so the runtime still owns one
    # bounded sprite image per action and all transitions remain opaque.
    neutral = normalized_lounge[7]
    for effect_name, filename in XIAOHEI_EFFECT_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{effect_name}.png",
        )
        with Image.open(io.BytesIO(source)) as opened:
            effect = opened.convert("RGBA")
        if effect_name == "cloud":
            make_xiaohei_effect_strip(
                neutral,
                effect,
                target_width=106,
                right=238,
                top=10,
                output=OUTPUT / "xiaohei" / "idle-cloud.webp",
            )
        else:
            make_xiaohei_effect_strip(
                neutral,
                effect,
                target_width=76,
                right=236,
                top=12,
                output=OUTPUT / "xiaohei" / "idle-sun.webp",
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
