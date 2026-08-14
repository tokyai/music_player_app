from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
CANVAS = 2048

INK = (13, 32, 48, 255)
INK_SOFT = (22, 62, 83, 255)
PAPER = (247, 251, 252, 255)
PAPER_SHADE = (226, 241, 245, 255)
BLUE = (33, 150, 243, 255)
MINT = (69, 211, 168, 255)
CORAL = (255, 179, 107, 255)


def _scaled(value: float) -> int:
    return round(value * CANVAS)


def _bezier(p0, p1, p2, p3, steps=24):
    points = []
    for index in range(steps + 1):
        t = index / steps
        u = 1 - t
        x = u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1]
        points.append((_scaled(x), _scaled(y)))
    return points


def _draw_mark(draw: ImageDraw.ImageDraw) -> None:
    draw.ellipse(
        (_scaled(0.18), _scaled(0.18), _scaled(0.82), _scaled(0.82)),
        fill=INK_SOFT,
    )

    left_page = [
        (_scaled(0.50), _scaled(0.31)),
        *_bezier((0.50, 0.31), (0.43, 0.27), (0.34, 0.26), (0.26, 0.30)),
        (_scaled(0.26), _scaled(0.70)),
        *_bezier((0.26, 0.70), (0.34, 0.66), (0.43, 0.68), (0.50, 0.73)),
    ]
    right_page = [
        (_scaled(0.50), _scaled(0.31)),
        *_bezier((0.50, 0.31), (0.57, 0.27), (0.66, 0.26), (0.74, 0.30)),
        (_scaled(0.74), _scaled(0.70)),
        *_bezier((0.74, 0.70), (0.66, 0.66), (0.57, 0.68), (0.50, 0.73)),
    ]
    draw.polygon(left_page, fill=PAPER)
    draw.polygon(right_page, fill=PAPER_SHADE)

    draw.rounded_rectangle(
        (_scaled(0.275), _scaled(0.315), _scaled(0.305), _scaled(0.675)),
        radius=_scaled(0.015),
        fill=MINT,
    )
    draw.rounded_rectangle(
        (_scaled(0.695), _scaled(0.315), _scaled(0.725), _scaled(0.675)),
        radius=_scaled(0.015),
        fill=CORAL,
    )
    draw.rounded_rectangle(
        (_scaled(0.492), _scaled(0.305), _scaled(0.508), _scaled(0.722)),
        radius=_scaled(0.008),
        fill=INK,
    )

    draw.ellipse(
        (_scaled(0.405), _scaled(0.425), _scaled(0.595), _scaled(0.615)),
        fill=BLUE,
        outline=INK,
        width=_scaled(0.012),
    )
    draw.polygon(
        [
            (_scaled(0.475), _scaled(0.468)),
            (_scaled(0.475), _scaled(0.572)),
            (_scaled(0.558), _scaled(0.520)),
        ],
        fill=PAPER,
    )


def _build_logo(round_icon: bool = False) -> Image.Image:
    image = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    bounds = (0, 0, CANVAS - 1, CANVAS - 1)
    if round_icon:
        draw.ellipse(bounds, fill=INK)
    else:
        draw.rounded_rectangle(bounds, radius=_scaled(0.22), fill=INK)
    _draw_mark(draw)
    return image


def _build_foreground() -> Image.Image:
    image = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    _draw_mark(ImageDraw.Draw(image))
    return image


def _save(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)


def main() -> None:
    logo = _build_logo()
    round_logo = _build_logo(round_icon=True)
    foreground = _build_foreground()

    _save(logo, ROOT / 'assets/images/app_logo.png', 1024)

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
        _save(foreground, folder / 'ic_launcher_foreground.png', foreground_sizes[density])


if __name__ == '__main__':
    main()
