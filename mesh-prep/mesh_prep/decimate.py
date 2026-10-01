"""Reducción de polígonos a un número de triángulos objetivo."""
from __future__ import annotations

import tempfile
from pathlib import Path

import pymeshlab as pml
import trimesh


def decimate_to_target(mesh: trimesh.Trimesh, target_triangles: int = 200_000) -> trimesh.Trimesh:
    if len(mesh.faces) <= target_triangles:
        return mesh

    with tempfile.TemporaryDirectory(prefix="scanforge_decimate_") as tmp:
        in_path = Path(tmp) / "in.ply"
        out_path = Path(tmp) / "out.ply"
        mesh.export(str(in_path))

        ms = pml.MeshSet()
        ms.load_new_mesh(str(in_path))
        ms.meshing_decimation_quadric_edge_collapse(
            targetfacenum=target_triangles,
            preservetopology=True,
            preserveboundary=True,
            optimalplacement=True,
            autoclean=True,
        )
        ms.save_current_mesh(str(out_path))
        decimated = trimesh.load(str(out_path), process=False, force="mesh")

    if isinstance(decimated, trimesh.Scene):
        decimated = trimesh.util.concatenate(list(decimated.geometry.values()))
    return decimated
