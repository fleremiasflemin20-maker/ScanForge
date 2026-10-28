"""Carga y exportación de mallas: OBJ/USDZ de entrada, 3MF/STL de salida."""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import trimesh


class MeshLoadError(Exception):
    pass


def load_mesh(path: Path) -> trimesh.Trimesh:
    """Carga un OBJ directamente, o un USDZ convirtiéndolo primero a OBJ."""
    path = Path(path)
    if not path.exists():
        raise MeshLoadError(f"No existe el archivo de entrada: {path}")

    suffix = path.suffix.lower()
    if suffix in (".obj", ".stl"):
        return _load_obj(path)
    if suffix == ".ply":
        return _load_ply(path)
    if suffix == ".usdz":
        obj_path = _convert_usdz_to_obj(path)
        return _load_obj(obj_path)
    raise MeshLoadError(f"Formato de entrada no soportado: {suffix} (usa .obj, .stl, .ply o .usdz)")


def _load_ply(path: Path) -> trimesh.Trimesh:
    """Un PLY con caras se carga tal cual; uno sin caras es una nube de puntos de
    ScanForge Pro (modos LiDAR Fusión / Micro TrueDepth) y se malla con Poisson."""
    loaded = trimesh.load(str(path), process=False)
    if isinstance(loaded, trimesh.Trimesh) and len(loaded.faces) > 0:
        return loaded
    points = np.asarray(getattr(loaded, "vertices", []), dtype=np.float64)
    if len(points) < 100:
        raise MeshLoadError(f"La nube de puntos tiene muy pocos puntos ({len(points)}): {path}")
    normals = _ply_normals(path, len(points))
    return poisson_from_points(points, normals)


def _ply_normals(path: Path, count: int) -> np.ndarray | None:
    """Lee nx/ny/nz del PLY con pymeshlab (trimesh no los expone para nubes de puntos)."""
    import pymeshlab

    try:
        ms = pymeshlab.MeshSet()
        ms.load_new_mesh(str(path))
        normals = np.asarray(ms.current_mesh().vertex_normal_matrix(), dtype=np.float64)
    except Exception:
        return None
    if normals.shape != (count, 3) or not np.any(normals):
        return None
    return normals


def poisson_from_points(points: np.ndarray, normals: np.ndarray | None, depth: int = 9) -> trimesh.Trimesh:
    """Reconstrucción de Poisson (screened) de una nube de puntos orientada.

    Poisson siempre produce una superficie cerrada, también donde no hubo datos
    (debajo del objeto, huecos). Se recortan las caras alejadas de la nube original
    más de ~3 veces la separación típica entre puntos, para no inventar geometría."""
    import pymeshlab
    from scipy.spatial import cKDTree

    ms = pymeshlab.MeshSet()
    if normals is not None:
        ms.add_mesh(pymeshlab.Mesh(vertex_matrix=points, v_normals_matrix=normals))
    else:
        ms.add_mesh(pymeshlab.Mesh(vertex_matrix=points))
        ms.compute_normal_for_point_clouds(k=12, smoothiter=2)
    ms.generate_surface_reconstruction_screened_poisson(depth=depth, preclean=True)
    m = ms.current_mesh()
    mesh = trimesh.Trimesh(vertices=m.vertex_matrix(), faces=m.face_matrix(), process=True)

    tree = cKDTree(points)
    spacing = float(np.median(tree.query(points, k=2)[0][:, 1]))
    distances, _ = tree.query(mesh.vertices)
    keep_vertex = distances <= max(spacing * 3.0, 1e-9)
    keep_face = keep_vertex[mesh.faces].all(axis=1)
    mesh.update_faces(keep_face)
    mesh.remove_unreferenced_vertices()
    if len(mesh.faces) == 0:
        raise MeshLoadError("Poisson no generó caras útiles a partir de la nube de puntos.")
    return mesh


def _load_obj(path: Path) -> trimesh.Trimesh:
    loaded = trimesh.load(str(path), process=False, force="mesh")
    if isinstance(loaded, trimesh.Scene):
        geometries = list(loaded.geometry.values())
        if not geometries:
            raise MeshLoadError(f"El OBJ no contiene geometría: {path}")
        mesh = trimesh.util.concatenate(geometries)
    else:
        mesh = loaded
    if not isinstance(mesh, trimesh.Trimesh) or len(mesh.faces) == 0:
        raise MeshLoadError(f"No se pudo interpretar como malla triangular: {path}")
    return mesh


def _convert_usdz_to_obj(usdz_path: Path) -> Path:
    """Convierte USDZ -> OBJ. Intenta usd-core (pxr) primero; si no está disponible
    o falla, recurre a Blender en modo headless."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="scanforge_usdz_"))
    obj_out = tmp_dir / "converted.obj"

    try:
        _convert_usdz_with_usdcore(usdz_path, obj_out)
        return obj_out
    except Exception as usd_core_error:
        blender = shutil.which("blender")
        if blender is None:
            raise MeshLoadError(
                "No se pudo convertir el USDZ: usd-core falló "
                f"({usd_core_error}) y no se encontró 'blender' en el PATH para usarlo "
                "como alternativa. Instala 'usd-core' (pip install usd-core) o Blender."
            ) from usd_core_error
        _convert_usdz_with_blender(blender, usdz_path, obj_out)
        if not obj_out.exists():
            raise MeshLoadError(f"Blender no generó el OBJ esperado en {obj_out}")
        return obj_out


def _convert_usdz_with_usdcore(usdz_path: Path, obj_out: Path) -> None:
    from pxr import Usd, UsdGeom  # type: ignore

    stage = Usd.Stage.Open(str(usdz_path))
    if stage is None:
        raise MeshLoadError(f"usd-core no pudo abrir el stage: {usdz_path}")

    verts: list[tuple[float, float, float]] = []
    faces: list[tuple[int, int, int]] = []
    offset = 0

    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        xform_cache = UsdGeom.XformCache()
        world_matrix = xform_cache.GetLocalToWorldTransform(prim)

        points = mesh.GetPointsAttr().Get() or []
        counts = mesh.GetFaceVertexCountsAttr().Get() or []
        indices = mesh.GetFaceVertexIndicesAttr().Get() or []

        world_points = [world_matrix.Transform(p) for p in points]
        verts.extend((p[0], p[1], p[2]) for p in world_points)

        idx_cursor = 0
        for count in counts:
            face_indices = [indices[idx_cursor + i] + offset for i in range(count)]
            if count == 3:
                faces.append(tuple(face_indices))
            elif count > 3:
                # Fan triangulation de polígonos con más de 3 vértices.
                for i in range(1, count - 1):
                    faces.append((face_indices[0], face_indices[i], face_indices[i + 1]))
            idx_cursor += count
        offset += len(points)

    if not verts or not faces:
        raise MeshLoadError("usd-core no encontró geometría de malla en el USDZ.")

    with open(obj_out, "w", encoding="utf-8") as f:
        for v in verts:
            f.write(f"v {v[0]} {v[1]} {v[2]}\n")
        for face in faces:
            f.write(f"f {face[0] + 1} {face[1] + 1} {face[2] + 1}\n")


def _convert_usdz_with_blender(blender_bin: str, usdz_path: Path, obj_out: Path) -> None:
    script = f"""
import bpy
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=r"{usdz_path}")
bpy.ops.wm.obj_export(filepath=r"{obj_out}", export_selected_objects=False)
"""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write(script)
        script_path = f.name

    result = subprocess.run(
        [blender_bin, "--background", "--python", script_path],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode != 0:
        raise MeshLoadError(f"Blender falló al convertir USDZ->OBJ:\n{result.stderr}")


def export_mesh(mesh: trimesh.Trimesh, output_dir: Path, basename: str) -> dict[str, Path]:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    paths = {
        "3mf": output_dir / f"{basename}.3mf",
        "stl": output_dir / f"{basename}.stl",
    }
    mesh.export(str(paths["3mf"]))
    mesh.export(str(paths["stl"]))
    return paths
