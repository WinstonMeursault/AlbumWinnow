#!/usr/bin/env python3
"""Generate full-resolution JPEG test images, with one exact pair per 20 assets.

JPEG restart intervals join independently encoded MCU strips. This avoids
re-encoding 12 million pixels for each image. All pixels are synthetic.
"""
import argparse
import io
import json
from pathlib import Path
import random
import struct
from PIL import Image, ImageDraw

WIDTH, HEIGHT, STRIP_HEIGHT = 4032, 3072, 96


def jpeg_parts(data):
    position = 2
    segments = []
    while position < len(data):
        assert data[position] == 0xFF
        marker = data[position + 1]
        length = int.from_bytes(data[position + 2:position + 4], 'big')
        segment = data[position:position + 2 + length]
        segments.append((marker, segment))
        position += 2 + length
        if marker == 0xDA:
            assert data[-2:] == b'\xff\xd9'
            return segments, data[position:-2]
    raise ValueError('Missing JPEG scan')


def strips(seed):
    rng = random.Random(seed)
    entropy, header = [], None
    for _ in range(1024):
        image = Image.new('RGB', (WIDTH, STRIP_HEIGHT))
        draw = ImageDraw.Draw(image)
        for column in range(32):
            color = tuple(rng.randrange(24, 233) for _ in range(3))
            draw.rectangle((column * 126, 0, (column + 1) * 126 - 1, STRIP_HEIGHT - 1), fill=color)
        output = io.BytesIO()
        image.save(output, format='JPEG', quality=85, subsampling=2, optimize=False)
        parts, payload = jpeg_parts(output.getvalue())
        normalized = []
        for marker, segment in parts:
            if marker == 0xC0:
                # Baseline, 4:2:0, 16x16 MCU; 252 MCUs per row.
                assert segment[9:] == bytes([3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
                segment = segment[:5] + struct.pack('>H', HEIGHT) + segment[7:]
            if marker == 0xDA:
                normalized.append(b'\xff\xdd\x00\x04' + struct.pack('>H', WIDTH // 16 * (STRIP_HEIGHT // 16)))
            normalized.append(segment)
        current = b'\xff\xd8' + b''.join(normalized)
        if header is None:
            header = current
        assert header == current, 'Strips must share coding tables'
        assert all(b'\xff' + bytes([marker]) not in payload for marker in range(0xD0, 0xD8))
        entropy.append(payload)
    return header, entropy


def picture(index, header, entropy, seed):
    rng = random.Random(seed + index * 104729)
    rows = [rng.choice(entropy) for _ in range(HEIGHT // STRIP_HEIGHT)]
    return header + b''.join(row + (b'\xff' + bytes([0xD0 + i % 8]) if i < len(rows) - 1 else b'')
                             for i, row in enumerate(rows)) + b'\xff\xd9'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--count', type=int, required=True)
    parser.add_argument('--seed', type=int, default=20261120)
    args = parser.parse_args()
    assert args.count > 0 and args.count % 200 == 0
    existing = args.root / 'dataset.json'
    if existing.exists():
        metadata = json.loads(existing.read_text())
        assert metadata['seed'] == args.seed and metadata['width'] == WIDTH and metadata['height'] == HEIGHT
        assert metadata['count'] <= args.count, 'Use a fresh root to generate a smaller dataset'
    photos, edits = args.root / 'photos', args.root / 'edits'
    photos.mkdir(parents=True, exist_ok=True)
    edits.mkdir(exist_ok=True)
    header, entropy = strips(args.seed)
    sample = picture(0, header, entropy, args.seed)
    # Decode the whole composed image, not just its header.
    with Image.open(io.BytesIO(sample)) as image:
        image.load()
        assert image.size == (WIDTH, HEIGHT)
    for index in range(args.count):
        target = photos / f'asset-{index:06}.jpg'
        if target.exists():
            continue
        data = picture(index - 1 if index % 20 == 1 else index, header, entropy, args.seed)
        target.write_bytes(data)
        if index % 10000 == 0:
            print(f'Generated {index}/{args.count}', flush=True)
    for index in range(args.count // 200):
        target = edits / f'edit-{index:06}.jpg'
        if not target.exists():
            target.write_bytes(picture(1_000_000 + index, header, entropy, args.seed))
    summary = {'count': args.count, 'width': WIDTH, 'height': HEIGHT, 'seed': args.seed,
               'exact_pairs': args.count // 20, 'changed_assets': args.count // 100,
               'sample_bytes': len(sample), 'kind': 'synthetic full-resolution JPEG; not natural photos'}
    (args.root / 'dataset.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
