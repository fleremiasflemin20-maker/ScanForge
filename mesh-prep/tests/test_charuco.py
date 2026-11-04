"""Escala con ChArUco: con vistas sintéticas del tablero (cámara conocida) y una
"reconstrucción" en otra escala/orientación, `solve` debe recuperar la escala real."""
from __future__ import annotations

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

from mesh_prep import charuco

W, H = 2000, 1500
K = np.array([[1700.0, 0, W / 2], [0, 1700.0, H / 2], [0, 0, 1]])


def _render_views(n: int = 12, elevations=(35, 55, 72)):
    board = charuco.make_board()
    px_per_mm = 10.0
    side_mm = charuco.SQUARES[0] * charuco.SQUARE_MM
    tex = board.generateImage((int(side_mm * px_per_mm),) * 2, marginSize=0, borderBits=1)
    target = np.array([side_mm / 2, side_mm / 2, 0.0])
    images, centers = {}, []
    for i in range(n * len(elevations)):
        theta = 2 * np.pi * (i % n) / n + 0.2 * (i // n)
        phi = np.radians(elevations[i // n])
        c = target + 330 * np.array([np.cos(theta) * np.cos(phi), np.sin(theta) * np.cos(phi), -np.sin(phi)])
        z = (target - c) / np.linalg.norm(target - c)
        x = np.cross(z, [0, 0, -1.0]); x /= np.linalg.norm(x)
        y = np.cross(z, x)
        r = np.vstack([x, y, z])
        t = -r @ c
        hom = K @ np.column_stack([r[:, 0], r[:, 1], t]) @ np.diag([1 / px_per_mm, 1 / px_per_mm, 1])
        img = cv2.warpPerspective(tex, hom, (W, H), borderValue=200)
        images[f"ring{i // n}-{i:03d}.png"] = img
        centers.append(c)
    return images, np.array(centers)


def test_umeyama_recovers_similarity():
    rng = np.random.default_rng(0)
    src = rng.normal(size=(20, 3))
    rot = Rotation.from_euler("xyz", [20, -35, 70], degrees=True).as_matrix()
    dst = 3.7 * src @ rot.T + [1, 2, 3]
    s, r, t = charuco.umeyama(src, dst)
    assert abs(s - 3.7) < 1e-9 and np.allclose(r, rot) and np.allclose(t, [1, 2, 3])


def test_solve_recovers_real_scale_from_board():
    images, true_centers = _render_views()
    # Focal del "EXIF" con un 5 % de error: la calibración debe corregirla.
    views = charuco.camera_centers(images, charuco.make_board(), focal_px=1700.0 * 1.05)
    # La "fotogrametría" ve las cámaras en metros, rotadas y desplazadas, sin escala real.
    rot = Rotation.from_euler("xyz", [90, 10, -30], degrees=True).as_matrix()
    recon = (true_centers * 0.001 / 1.3) @ rot.T + [0.4, -0.2, 0.1]
    poses = {name: {"t": recon[i].tolist(), "q": [0, 0, 0, 1]} for i, name in enumerate(sorted(images))}

    result = charuco.solve(views, poses)

    assert abs(result["escala"] / 1300.0 - 1) < 0.003  # escala real dentro de ±0,3 %
    assert result["residuo_medio_mm"] < 1.0
    # El tablero queda en Z=0 con las cámaras arriba (Z > 0).
    m = np.array(result["matriz"])
    mapped = recon @ m[:3, :3].T + m[:3, 3]
    assert (mapped[:, 2] > 100).all()
