"""Modo pieza mecánica: una pieza ranurada escaneada con ruido debe recuperar caras
planas y la medida de la ranura."""
from __future__ import annotations

import numpy as np
import trimesh

from mesh_prep import mechanical


def _slotted_block() -> trimesh.Trimesh:
    """Bloque 60x30x20 mm con una ranura de 10 mm de ancho y 8 de profundidad."""
    block = trimesh.creation.box(extents=[60, 30, 20])
    slot = trimesh.creation.box(extents=[10, 40, 8])
    slot.apply_translation([0, 0, 10 - 4 + 0.001])
    part = trimesh.boolean.difference([block, slot], engine="manifold")
    return part.subdivide_to_size(1.0)


def _scan_noise(mesh: trimesh.Trimesh, sigma: float = 0.15, seed: int = 0) -> trimesh.Trimesh:
    noisy = mesh.copy()
    rng = np.random.default_rng(seed)
    noisy.vertices = noisy.vertices + rng.normal(0, sigma, noisy.vertices.shape)
    return noisy


def _slot_wall_x(mesh: trimesh.Trimesh, side: float) -> float:
    """Posición X media de una pared de la ranura (vértices dentro de la ranura)."""
    v = mesh.vertices
    inside = (v[:, 2] > 3) & (v[:, 2] < 9) & (np.abs(v[:, 1]) < 13)
    wall = inside & (np.abs(v[:, 0] - side * 5) < 0.8)
    return float(v[wall, 0].mean()), float(v[wall, 0].std())


def test_flatten_restores_planar_slot_walls():
    clean = _slotted_block()
    noisy = _scan_noise(clean)
    _, noisy_std = _slot_wall_x(noisy, 1)

    flat = noisy
    for _ in range(2):
        flat, applied = mechanical.flatten_planar_faces(flat)

    assert applied >= 8  # 6 caras del bloque + fondo y paredes de la ranura
    left, left_std = _slot_wall_x(flat, -1)
    right, right_std = _slot_wall_x(flat, 1)
    assert right_std < noisy_std * 0.35  # la pared queda plana
    assert abs((right - left) - 10.0) < 0.1  # ancho de ranura exacto (±0,1 mm)


def test_curved_surfaces_are_not_flattened():
    cylinder = trimesh.creation.cylinder(radius=10, height=20, sections=128).subdivide_to_size(1.0)
    flat, _ = mechanical.flatten_planar_faces(_scan_noise(cylinder, 0.05))
    radial = np.linalg.norm(flat.vertices[:, :2], axis=1)
    side = np.abs(flat.vertices[:, 2]) < 9
    assert abs(np.median(radial[side]) - 10.0) < 0.1  # el lateral sigue siendo redondo
