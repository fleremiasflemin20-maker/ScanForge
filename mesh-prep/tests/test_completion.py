"""El completado debe reconstruir una pieza a la que le falta un trozo grande:
salir cerrada (imprimible) y casi idéntica a la pieza completa."""
from __future__ import annotations

import numpy as np
import trimesh
from scipy.spatial import cKDTree

from mesh_prep import completion


def _symmetric_part() -> trimesh.Trimesh:
    """Pieza simétrica respecto al plano X=0 pero no trivial: cuerpo con dos orejas y
    un saliente (como un soporte o una figura)."""
    body = trimesh.creation.box(extents=[40, 20, 30])
    ear_l = trimesh.creation.cylinder(radius=6, height=8, sections=48)
    ear_l.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [0, 1, 0]))
    ear_r = ear_l.copy()
    ear_l.apply_translation([-23, 0, 8])
    ear_r.apply_translation([23, 0, 8])
    nose = trimesh.creation.icosphere(subdivisions=3, radius=7)
    nose.apply_translation([0, -10, 0])
    part = trimesh.boolean.union([body, ear_l, ear_r, nose], engine="manifold")
    return part.subdivide_to_size(1.5)


def _cut_away(mesh: trimesh.Trimesh, keep: np.ndarray) -> trimesh.Trimesh:
    damaged = mesh.copy()
    damaged.update_faces(keep)
    damaged.remove_unreferenced_vertices()
    return damaged


def _mean_error(a: trimesh.Trimesh, b: trimesh.Trimesh) -> float:
    """Distancia media simétrica entre superficies (mm)."""
    pa, _ = trimesh.sample.sample_surface(a, 20000, seed=1)
    pb, _ = trimesh.sample.sample_surface(b, 20000, seed=2)
    return float((cKDTree(pb).query(pa)[0].mean() + cKDTree(pa).query(pb)[0].mean()) / 2)


def _without_right_ear(part: trimesh.Trimesh) -> trimesh.Trimesh:
    return _cut_away(part, ~(part.triangles_center[:, 0] > 19))


def test_poisson_completion_closes_large_hole():
    sphere = trimesh.creation.icosphere(subdivisions=5, radius=30)
    damaged = _cut_away(sphere, sphere.triangles_center[:, 2] > -18)  # sin el "polo" de abajo
    assert not damaged.is_watertight

    completed = completion.complete_watertight(damaged)

    assert completed.is_watertight
    assert _mean_error(completed, sphere) < 0.6  # mm, en una esfera de 60 mm


def test_symmetry_detects_mirror_plane_despite_missing_ear():
    damaged = _without_right_ear(_symmetric_part())

    plane = completion.detect_mirror_symmetry(damaged)

    assert plane is not None
    assert abs(plane.normal[0]) > 0.99  # el plano X=0
    assert abs(plane.offset) < 1.0


def test_symmetry_rebuilds_missing_ear():
    part = _symmetric_part()
    damaged = _without_right_ear(part)

    plane = completion.detect_mirror_symmetry(damaged)
    points, normals = completion.symmetry_fill_points(damaged, plane)
    with_symmetry = completion.complete_watertight(damaged, points, normals)
    plain = completion.complete_watertight(damaged)

    assert with_symmetry.is_watertight
    # La oreja reconstruida está donde debe: la pieza vuelve a medir 62 mm de ancho.
    assert with_symmetry.extents[0] == np.float64(with_symmetry.extents[0])
    assert abs(with_symmetry.extents[0] - part.extents[0]) < 1.0
    assert _mean_error(with_symmetry, part) < 0.5
    assert _mean_error(with_symmetry, part) < _mean_error(plain, part)


def test_asymmetric_part_is_not_mirrored():
    part = trimesh.creation.box(extents=[40, 20, 30])
    spike = trimesh.creation.cone(radius=6, height=25, sections=32)
    spike.apply_translation([12, 4, 15])
    side = trimesh.creation.box(extents=[10, 30, 6])
    side.apply_translation([-20, -8, -10])
    lumpy = trimesh.boolean.union([part, spike, side], engine="manifold")

    assert completion.detect_mirror_symmetry(lumpy) is None
