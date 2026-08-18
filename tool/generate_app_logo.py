from collections import deque
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tool/assets/app_logo_source.png'
ADAPTIVE_FOREGROUND_SOURCE = (
    ROOT / 'tool/assets/app_logo_adaptive_foreground.png'
)
MASTER_SIZE = 1024
APP_ASSET_SIZE = 512
BACKGROUND_LIMIT = 64
NOISE_FLOOR = 12


def _remove_connected_black_background(source: Image.Image) -> Image.Image:
    rgb = source.convert('RGB')
    width, height = rgb.size
    pixels = rgb.load()
    seen = bytearray(width * height)
    outside = bytearray(width * height)
    queue: deque[int] = deque()

    def enqueue(x: int, y: int) -> None:
        index = y * width + x
        if seen[index]:
            return
        seen[index] = 1
        red, green, blue = pixels[x, y]
        if max(red, green, blue) <= BACKGROUND_LIMIT:
            queue.append(index)

    for x in range(width):
        enqueue(x, 0)
        enqueue(x, height - 1)
    for y in range(1, height - 1):
        enqueue(0, y)
        enqueue(width - 1, y)

    while queue:
        index = queue.popleft()
        outside[index] = 1
        x = index % width
        y = index // width
        if x > 0:
            enqueue(x - 1, y)
        if x + 1 < width:
            enqueue(x + 1, y)
        if y > 0:
            enqueue(x, y - 1)
        if y + 1 < height:
            enqueue(x, y + 1)

    raw_rgb = rgb.tobytes()
    raw_rgba = bytearray(width * height * 4)
    for index in range(width * height):
        rgb_offset = index * 3
        rgba_offset = index * 4
        red, green, blue = raw_rgb[rgb_offset:rgb_offset + 3]
        alpha = 255
        if outside[index]:
            brightness = max(red, green, blue)
            if brightness <= NOISE_FLOOR:
                alpha = 0
            else:
                alpha = round(
                    (brightness - NOISE_FLOOR)
                    * 255
                    / (255 - NOISE_FLOOR)
                )
                scale = 255 / alpha
                red = min(255, round(red * scale))
                green = min(255, round(green * scale))
                blue = min(255, round(blue * scale))
        raw_rgba[rgba_offset:rgba_offset + 4] = bytes(
            (red, green, blue, alpha)
        )

    cutout = Image.frombytes('RGBA', (width, height), bytes(raw_rgba))
    alpha = cutout.getchannel('A')
    alpha = alpha.filter(ImageFilter.MinFilter(5))
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.7))
    cutout.putalpha(alpha)
    bounds = alpha.point(lambda value: 255 if value >= 4 else 0).getbbox()
    if bounds is None:
        raise ValueError('No icon subject was found in the source image.')

    cropped = cutout.crop(bounds)
    side = max(cropped.size)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.alpha_composite(
        cropped,
        ((side - cropped.width) // 2, (side - cropped.height) // 2),
    )
    return square.resize(
        (MASTER_SIZE, MASTER_SIZE),
        Image.Resampling.LANCZOS,
    )


def _build_round_logo(logo: Image.Image) -> Image.Image:
    mask = Image.new('L', logo.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, logo.width - 1, logo.height - 1), fill=255)
    result = logo.copy()
    result.putalpha(ImageChops.multiply(logo.getchannel('A'), mask))
    return result


def _save(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(
        path,
        optimize=True,
        compress_level=9,
    )


def main() -> None:
    with Image.open(SOURCE) as source:
        logo = _remove_connected_black_background(source)
    with Image.open(ADAPTIVE_FOREGROUND_SOURCE) as source:
        foreground = source.convert('RGBA').resize(
            (MASTER_SIZE, MASTER_SIZE),
            Image.Resampling.LANCZOS,
        )
    round_logo = _build_round_logo(logo)

    _save(logo, ROOT / 'assets/images/app_logo.png', APP_ASSET_SIZE)

    densities = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
    }
    foreground_sizes = {
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
        'xxxhdpi': 432,
    }
    res = ROOT / 'android/app/src/main/res'
    for density, size in densities.items():
        folder = res / f'mipmap-{density}'
        _save(logo, folder / 'ic_launcher.png', size)
        _save(round_logo, folder / 'ic_launcher_round.png', size)
        _save(
            foreground,
            folder / 'ic_launcher_foreground.png',
            foreground_sizes[density],
        )


if __name__ == '__main__':
    main()
