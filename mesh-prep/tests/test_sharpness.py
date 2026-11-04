"""Las fotos movidas de un anillo deben descartarse y las nítidas enlazarse."""
from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np

from mesh_prep import sharpness


def _textured(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    img = np.full((600, 800, 3), 128, np.uint8)
    for _ in range(300):
        x, y = rng.integers(0, 800), rng.integers(0, 600)
        cv2.circle(img, (int(x), int(y)), int(rng.integers(3, 20)), tuple(int(c) for c in rng.integers(0, 255, 3)), -1)
    return img


def test_blurry_photos_are_rejected(tmp_path: Path):
    blurry = {"mid-004.jpg", "mid-009.jpg"}
    for i in range(12):
        name = f"mid-{i:03d}.jpg"
        img = _textured(i)
        if name in blurry:
            img = cv2.GaussianBlur(img, (0, 0), 6)  # foto movida
        cv2.imwrite(str(tmp_path / name), img)

    entries = sharpness.rank(tmp_path)
    rejected = {e["archivo"] for e in entries if not e["aceptada"]}
    assert rejected == blurry

    out = tmp_path / "nitidas"
    assert sharpness.stage(tmp_path, out, entries) == 10
    assert (out / "mid-000.jpg").is_symlink() and not (out / "mid-004.jpg").exists()
    assert (out / "nitidez.json").exists()
