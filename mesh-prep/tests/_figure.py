"""Figura sintética tipo muñeco: torso, cuello, cabeza, pelo (otro color) y dos brazos."""
from __future__ import annotations

import manifold3d as mf
import numpy as np
import trimesh

from mesh_prep.parts import to_manifold, to_trimesh

SKIN = np.array([0.96, 0.80, 0.69])
HAIR = np.array([0.15, 0.20, 0.75])
SHIRT = np.array([0.85, 0.10, 0.12])


def figure() -> trimesh.Trimesh:
    torso = mf.Manifold.cube((30, 18, 40), center=True)
    neck = mf.Manifold.cylinder(10, 5, circular_segments=48).translate((0, 0, 18))
    head = mf.Manifold.sphere(13, circular_segments=96).translate((0, 0, 38))
    arm_l = mf.Manifold.cylinder(34, 4.5, circular_segments=48).rotate((0, 90, 0)).translate((14, 0, 12))
    arm_r = mf.Manifold.cylinder(34, 4.5, circular_segments=48).rotate((0, -90, 0)).translate((-14, 0, 12))
    body = mf.Manifold.batch_boolean([torso, neck, head, arm_l, arm_r], mf.OpType.Add)
    return to_trimesh(body).subdivide_to_size(1.2)


def colored_figure() -> trimesh.Trimesh:
    mesh = figure()
    v = mesh.vertices
    colors = np.tile(SKIN, (len(v), 1))
    colors[(v[:, 2] > 42)] = HAIR  # casquete de pelo
    colors[(v[:, 2] < 20) & (np.abs(v[:, 0]) < 15.5)] = SHIRT  # camiseta en el torso
    mesh.visual.vertex_colors = np.hstack([colors * 255, np.full((len(v), 1), 255)]).astype(np.uint8)
    return mesh
