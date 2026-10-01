"""Carga y exportación de mallas: OBJ/USDZ de entrada, 3MF/STL de salida."""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import trimesh


class MeshLoadError(Exception):
    pass


def load_mesh(path: Path) -> trimesh.Trimesh:
    """Carga un OBJ directamente, o un USDZ convirtiéndolo primero a OBJ."""
    path = Path(path)
    if not path.exists():
        raise MeshLoadError(f"No existe el archivo de entrada: {path}")

    suffix = path.suffix.lower()
    if suffix == ".obj":
        return _load_obj(path)
    if suffix == ".usdz":
        obj_path = _convert_usdz_to_obj(path)
        return _load_obj(obj_path)
    raise MeshLoadError(f"Formato de entrada no soportado: {suffix} (usa .obj o .usdz)")


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
