"""Limpieza de malla: quita fragmentos sueltos, rellena agujeros y repara no-manifold."""
from __future__ import annotations

import tempfile
from pathlib import Path

import pymeshlab as pml
import trimesh


def keep_largest_component(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    """Separa la malla en componentes conectados y se queda con el de mayor volumen/área.
    Elimina ruido de la reconstrucción (motas sueltas, fragmentos del fondo que no se
    unieron al objeto principal)."""
    components = mesh.split(only_watertight=False)
    if len(components) <= 1:
        return mesh

    def score(m: trimesh.Trimesh) -> float:
        # El volumen solo es significativo si la pieza es watertight; si no, usamos área
        # como proxy de tamaño para no descartar la pieza principal por casualidad.
        try:
            if m.is_watertight:
                return abs(m.volume)
        except Exception:
            pass
        return m.area

    largest = max(components, key=score)
    return largest


def fill_holes_and_repair(mesh: trimesh.Trimesh, max_hole_size: int = 500) -> trimesh.Trimesh:
    """Rellena agujeros pequeños (ruido de escaneo) y repara aristas/vértices no-manifold
    usando pymeshlab. `max_hole_size` es el número máximo de aristas de un agujero a
    rellenar (agujeros más grandes que eso no se tocan aquí; la base plana se genera
    aparte en orientation.generate_flat_base)."""
    with tempfile.TemporaryDirectory(prefix="scanforge_cleanup_") as tmp:
        in_path = Path(tmp) / "in.ply"
        out_path = Path(tmp) / "out.ply"
        mesh.export(str(in_path))

        ms = pml.MeshSet()
        ms.load_new_mesh(str(in_path))

        ms.meshing_remove_duplicate_faces()
        ms.meshing_remove_duplicate_vertices()
        ms.meshing_remove_unreferenced_vertices()
        ms.meshing_repair_non_manifold_edges()
        ms.meshing_repair_non_manifold_vertices()
        ms.meshing_close_holes(maxholesize=max_hole_size, refinehole=True)

        ms.save_current_mesh(str(out_path))
        repaired = trimesh.load(str(out_path), process=False, force="mesh")

    if isinstance(repaired, trimesh.Scene):
        repaired = trimesh.util.concatenate(list(repaired.geometry.values()))

    repaired.fix_normals()
    return repaired
