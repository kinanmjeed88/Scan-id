#!/usr/bin/env python3
"""Independent PDF parsing/rasterization and PNG/JPEG density checks on real output."""
from pathlib import Path
import fitz
from PIL import Image

root = Path('diagnostics')
def color(image, x, y, channel, dpi=300):
    rgb = image.convert('RGB').getpixel((round(x / 25.4 * dpi), round(y / 25.4 * dpi)))
    assert rgb[channel] > 240 and rgb[2 if channel == 0 else 0] < 15, (x, y, rgb)

for name in ('export-proof.pdf', 'export-proof-600.pdf'):
    doc = fitz.open(root / name)
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
for extension in ('png', 'jpg'):
    image = Image.open(root / f'export-proof-600.{extension}')
    assert image.size == (7016, 4961)
    assert all(abs(dpi - 600) < .02 for dpi in image.info['dpi'])
    color(image, 25, 35, 0, dpi=600)
    color(image, 65, 35, 2, dpi=600)
# Fixtures produced by document_exporter_test.dart, not generated here. Verify
# image embedding/placement through a different parser than the Dart library.
def image_rect_mm(page, xref, expected):
    rectangles = page.get_image_rects(xref)
    assert len(rectangles) == 1, rectangles
    actual = tuple(value / 72 * 25.4 for value in rectangles[0])
    assert all(abs(a - b) < .002 for a, b in zip(actual, expected)), (actual, expected)


def contained_pixels(image, index):
    if index == 0:
        color(image, 22.7, 35.4, 0)
        color(image, 48.1, 35.4, 2)
        blank = (35.4, 20)
    else:
        color(image, 60.8, 35.4, 0)
        color(image, 60.8, 86.2, 2)
        blank = (35.4, 60.8)
    rgb = image.convert('RGB').getpixel(tuple(round(mm / 25.4 * 300) for mm in blank))
    assert min(rgb) > 245, (blank, rgb)


for name, count, dimensions in (
    ('export-contain-selected.pdf', 1, (600, 60)),
    ('export-contain-proof.pdf', 2, (1200, 120)),
):
    with fitz.open(root / name) as doc:
        assert len(doc) == count
        xrefs = set()
        for index, page in enumerate(doc):
            assert abs(page.rect.width - 210 / 25.4 * 72) < .01
            assert abs(page.rect.height - 297 / 25.4 * 72) < .01
            images = page.get_images(full=True)
            assert len(images) == 1, images
            xref, smask, width, height, *_ = images[0]
            assert all(wanted <= actual <= wanted + 1 for actual, wanted in
                       zip((width, height), dimensions)), (width, height, dimensions)
            if smask:
                mask = doc.extract_image(smask)
                assert (mask['width'], mask['height']) == (width, height)
            xrefs.add(xref)
            image_rect_mm(page, xref, (10, 32.86, 60.8, 37.94) if index == 0
                          else (55.72, 10, 65.88, 111.6))
            pix = page.get_pixmap(dpi=300, alpha=False)
            contained_pixels(Image.frombytes('RGB', (pix.width, pix.height), pix.samples), index)
        assert len(xrefs) == 1, 'The same asset must share one PDF embedding'

for index in (0, 1):
    with Image.open(root / f'export-contain-{index}.png') as image:
        assert image.size == (2480, 3508)
        assert all(abs(dpi - 300) < .02 for dpi in image.info['dpi'])
        contained_pixels(image, index)

with fitz.open(root / 'export-contain-rounding.pdf') as doc:
    assert len(doc) == 1
    images = doc[0].get_images(full=True)
    assert len(images) == 1
    xref, _, width, height, *_ = images[0]
    assert (width, height) == (591, 33), (width, height)
    # The rotated physical width must come from 2049:113, NOT 591:33.
    physical_width = 50 * 113 / 2049
    image_rect_mm(doc[0], xref, (35 - physical_width / 2, 10,
                               35 + physical_width / 2, 60))

print('Independent export audit passed: two A4 PDF pages, absolute mm positions, 90-degree rotation, PNG/JPEG at 300 and 600 DPI in portrait and landscape.')
print('Contained export audit passed: selected-page resolution, shared embedding, blank margins, rotation, original-aspect placement after pixel rounding, and PNG/PDF parity.')
print('Raster dimensions round to whole pixels; this does not prove physical printer accuracy.')
