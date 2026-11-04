"""El kit de validación debe recuperar errores conocidos inyectados en artefactos
sintéticos (esfera, barra de esferas, plano)."""
from __future__ import annotations

import numpy as np
import trimesh

from mesh_prep import validate


def _noisy(mesh: trimesh.Trimesh, sigma: float, seed: int = 0) -> trimesh.Trimesh:
    m = mesh.copy()
    m.vertices = m.vertices + np.random.default_rng(seed).normal(0, sigma, m.vertices.shape)
    return m


def test_sphere_size_and_form_error():
    # Bola de 25,4 mm "escaneada" un 1 % grande y con ruido de 0,02 mm.
    ball = trimesh.creation.icosphere(subdivisions=5, radius=25.4 / 2 * 1.01)
    report = validate.validate(_noisy(ball, 0.02), sphere_diameter=25.4)
    assert abs(report["PS_error_tamano"] - 0.254) < 0.02
    assert 0.05 < report["PF_error_forma"] < 0.2  # rango ≈ ±3σ


def test_sphere_bar_spacing_error():
    a = trimesh.creation.icosphere(subdivisions=4, radius=12.7)
    b = a.copy()
    a.apply_translation([-50.0, 0, 0])
    b.apply_translation([50.3, 0, 0])  # barra de 100 mm medida 100,3
    bar = trimesh.creation.cylinder(radius=3, height=70)
    bar.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [0, 1, 0]))
    scene = trimesh.util.concatenate([a, b, bar])
    report = validate.validate(_noisy(scene, 0.01), sphere_diameter=25.4, spacing=100.0)
    assert abs(report["SD_error_distancia"] - 0.3) < 0.03


def test_plane_flatness():
    glass = trimesh.creation.box(extents=[120, 80, 6]).subdivide_to_size(2.0)
    v = glass.vertices.copy()
    top = v[:, 2] > 2.9
    v[top, 2] += 0.05 * np.cos(v[top, 0] / 120 * np.pi)  # comba de 0,05 mm
    glass.vertices = v
    # Apoyado en la mesa: la cara de abajo no se escanea.
    glass.update_faces(glass.triangles_center[:, 2] > -2.9)
    glass.remove_unreferenced_vertices()
    report = validate.validate(glass, plane=True)
    assert abs(report["F_planitud"] - 0.05) < 0.01
