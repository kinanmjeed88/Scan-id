#!/usr/bin/env python3
"""Independent PDF parsing/rasterization and PNG/JPEG density checks on real output."""
from pathlib import Path
import fitz
from PIL import Image

root = Path('diagnostics')
def color(image, x, y, channel, dpi=300):
    rgb = image.convert('RGB').getpixel((round(x / 25.4 * dpi), round(y / 25.4 * dpi)))
    assert rgb[channel] > 240 and rgb[2 if channel == 0 else 0] < 15, (x, y, rgb)

doc = fitz.open(root / 'export-proof.pdf')
assert len(doc) == 2
for index, page in enumerate(doc):
    assert abs(page.rect.width - 210 / 25.4 * 72) < .01
    assert abs(page.rect.height - 297 / 25.4 * 72) < .01
    pix = page.get_pixmap(dpi=300, alpha=False)
    image = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
    color(image, 25 if index == 0 else 85, 35 if index == 0 else 65, 0)
    color(image, 65 if index == 0 else 85, 35 if index == 0 else 105, 2)
for extension in ('png', 'jpg'):
    for page in (1, 2):
        image = Image.open(root / f'export-proof-300-{page}.{extension}')
        assert image.size == (2480, 3508)
        assert all(abs(dpi - 300) < .02 for dpi in image.info['dpi']), image.info
        color(image, 25 if page == 1 else 85, 35 if page == 1 else 65, 0)
        color(image, 65 if page == 1 else 85, 35 if page == 1 else 105, 2)
image = Image.open(root / 'export-proof-600.png')
assert image.size == (7016, 4961)
assert all(abs(dpi - 600) < .02 for dpi in image.info['dpi'])
print('Independent export audit passed: two A4 PDF pages, absolute mm positions, 90-degree rotation, PNG/JPEG at 300 DPI and landscape PNG at 600 DPI.')
print('Raster dimensions round to whole pixels; this does not prove physical printer accuracy.')
