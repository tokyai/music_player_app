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
# The dsh-xiaohei project is the canonical source for the current XiaoHei
# action set.  Keep the revision pinned: unlike a live GitHub URL this makes a
# regenerated bundle visually reproducible and lets reviewers verify exactly
# which authorised files were used.
XIAOHEI_DSH_COMMIT = "1fcd72ad24b1472fb74e2806b04a6392b055dbd9"
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

XIAOHEI_EXTRA_FILES = {
    "eat-watermelon": "eat-watermelon-txt.gif",
}

XIAOHEI_EFFECT_FILES = {
    "cloud": "smiling clouds.png",
    "sun": "emotion increasing animation.png",
}

# dsh's GIFs are deliberately kept as GIF inputs here (rather than decoding
# the prebuilt animated WebP files).  Flutter's sprite painter consumes one
# bounded horizontal strip, so the generator extracts and aligns the frames.
XIAOHEI_DSH_FILES = {
    "wave": "main-wave.gif",
    "run": "main-run.gif",
    "wiggle": "main-wiggle.gif",
    "roll": "main-roll.gif",
    "play": "main-play-heixiu.gif",
    "pillow": "main-pillow.gif",
    "full": "main-full.gif",
    "eat": "main-eat.gif",
    "sneak-eat": "main-sneak-eat.gif",
    "celebrate": "main-celebrate.gif",
}

XIAOHEI_DSH_STATIC_FILES = {
    "base": "main-base.png",
    "bored": "main-bored.png",
    "daze": "main-daze.png",
}

# main-wave contains a useful upright blink/settle lead-in followed by a long
# side-wave section.  The source GIF currently decodes to 34 frames. A
# 31-frame selection keeps the resulting 7936 px strip below the 8192 px
# texture limit on older Android GPUs while retaining every meaningful pose
# change (including both upright end frames).
XIAOHEI_DSH_FRAME_SELECTIONS = {
    "wave": [
        *range(0, 11),
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        26,
        28,
        30,
        31,
        32,
        33,
    ],
}

# The source's small companion animations are intentionally scaled up a bit
# when placed on the common stage.  This keeps a toy/sleeping pose readable in
# the 68–96 px assistant slot without changing the canonical base size.
XIAOHEI_DSH_SCALE_OVERRIDES = {
    "play": 2.2,
    "pillow": 2.2,
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


def normalize_frames(
    frames: list[Image.Image],
    *,
    scale_hint: float | None = None,
) -> list[Image.Image]:
    """Put a strip on one stable stage and align every frame to its baseline.

    The scale is calculated once from the strip's union alpha bounds rather
    than independently per frame.  That avoids an artificial zoom when a
    character changes pose, while the fixed baseline prevents the feet from
    hopping when switching between actions.  ``scale_hint`` lets a family of
    strips share the neutral pose's scale; it is still capped by the stage
    width so a wide roll cannot overflow the texture.
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
    if scale_hint is None:
        scale = min(
            PET_TARGET_HEIGHT / union_height,
            (PET_STAGE - 12) / union_width,
        )
    else:
        scale = min(scale_hint, (PET_STAGE - 12) / union_width)
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


def save_strip(
    frames: list[Image.Image],
    output: Path,
    *,
    scale_hint: float | None = None,
) -> None:
    if not frames:
        raise ValueError(f"No frames for {output}")
    frames = normalize_frames(frames, scale_hint=scale_hint)
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


def _image_from_payload(payload: bytes) -> Image.Image:
    """Decode one static image and detach it from the input stream."""
    with Image.open(io.BytesIO(payload)) as opened:
        return opened.convert("RGBA")


def _preferred_scale(frame: Image.Image) -> float:
    """Return the canonical XiaoHei scale derived from main-base."""
    rgba = frame.convert("RGBA")
    box = rgba.getchannel("A").getbbox()
    if box is None:
        raise ValueError("XiaoHei main-base has no visible pixels")
    width = box[2] - box[0]
    height = box[3] - box[1]
    return min(PET_TARGET_HEIGHT / height, (PET_STAGE - 12) / width)


def _download_dsh_xiaohei(filename: str) -> bytes:
    return download(
        raw_url("opensetk/dsh-xiaohei", XIAOHEI_DSH_COMMIT, f"assets/{filename}"),
        CACHE / "xiaohei-dsh" / filename,
    )


def build_xiaohei() -> None:
    """Build XiaoHei from the dsh-pet action family.

    The old lounge set used a separate half-lidded drawing for its neutral
    pose.  That made every state switch look like a character replacement.
    main-base is now the canonical neutral frame; every dsh action is aligned
    to its scale and baseline before being exported as a Flutter-friendly
    strip. Cloud/sun effects and the optional, stylistically different
    watermelon action still come from IXiaoHei.
    """
    output = OUTPUT / "xiaohei"
    base = _image_from_payload(_download_dsh_xiaohei("main-base.png"))
    reference_scale = _preferred_scale(base)

    # main-wave starts and ends on the exact base drawing.  Its first ten
    # frames are a restrained blink/settle cycle, so reuse them as the normal
    # low-frequency idle feedback instead of showing a full wave on idle.
    wave_frames = _load_gif_frames(_download_dsh_xiaohei("main-wave.gif"))
    idle_source = [base, *wave_frames[1:10]]
    idle_normalized = normalize_frames(
        idle_source,
        scale_hint=reference_scale,
    )
    neutral = idle_normalized[0]
    # The GIF's last upright drawing is visually the same pose but retains
    # palette/compression differences from main-base.  Reuse the canonical
    # pixels at both boundaries so the quiet idle cue settles without a
    # one-frame outline shimmer before returning to rest.
    idle_normalized[-1] = neutral.copy()
    save_stage_strip([neutral], output / "rest.webp")
    save_stage_strip(idle_normalized, output / "idle-blink.webp")

    for state, filename in XIAOHEI_DSH_FILES.items():
        if state == "wave":
            frames = wave_frames
            selection = XIAOHEI_DSH_FRAME_SELECTIONS["wave"]
            if max(selection, default=-1) >= len(frames):
                raise ValueError("main-wave frame selection exceeds source length")
            frames = [frames[index] for index in selection]
            normalized_wave = normalize_frames(
                frames,
                scale_hint=reference_scale,
            )
            # The source's first/last drawings are the same neutral pose as
            # main-base, but independent GIF normalization can move an edge
            # pixel by one device pixel. Publish the exact canonical stage at
            # both ends so a greeting can always cross-fade back to rest.
            normalized_wave[0] = neutral.copy()
            normalized_wave[-1] = neutral.copy()
            save_stage_strip(normalized_wave, output / "wave.webp")
            continue
        else:
            frames = _load_gif_frames(_download_dsh_xiaohei(filename))
        scale_hint = XIAOHEI_DSH_SCALE_OVERRIDES.get(state, reference_scale)
        save_strip(frames, output / f"{state}.webp", scale_hint=scale_hint)

    # Static long-idle expressions are exported as one-frame strips so they
    # use the same painter/transition path as every other action.
    for state, filename in XIAOHEI_DSH_STATIC_FILES.items():
        if state == "base":
            continue  # already emitted as the neutral rest strip above
        image = _image_from_payload(_download_dsh_xiaohei(filename))
        save_strip([image], output / f"{state}.webp", scale_hint=reference_scale)

    # Keep the authorized IXiaoHei watermelon action available for an explicit
    # future interaction. Its purple palette does not match the dsh family, so
    # the runtime deliberately excludes it from automatic idle scheduling.
    for state, filename in XIAOHEI_EXTRA_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{state}.gif",
        )
        save_strip(
            _load_gif_frames(source),
            output / f"{state}.webp",
            scale_hint=reference_scale,
        )

    # Cloud and sun are decorative source images, not replacement poses.  Bake
    # them onto the dsh main-base stage so the runtime owns one bounded image
    # and never has to reveal a transparent/white intermediate layer.
    for effect_name, filename in XIAOHEI_EFFECT_FILES.items():
        source = download(
            raw_url(
                "jiang-taibai/IXiaoHei",
                XIAOHEI_COMMIT,
                f"src/org/taibai/hellohei/img/{filename}",
            ),
            CACHE / f"xiaohei-{effect_name}.png",
        )
        effect = _image_from_payload(source)
        if effect_name == "cloud":
            make_xiaohei_effect_strip(
                neutral,
                effect,
                target_width=106,
                right=238,
                top=10,
                output=output / "idle-cloud.webp",
            )
        else:
            make_xiaohei_effect_strip(
                neutral,
                effect,
                target_width=76,
                right=236,
                top=12,
                output=output / "idle-sun.webp",
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
