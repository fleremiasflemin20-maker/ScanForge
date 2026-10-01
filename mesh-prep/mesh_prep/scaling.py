"""Escalado de la malla a milímetros reales."""
from __future__ import annotations

import trimesh


class ScalingError(Exception):
    pass


def scale_mesh(
    mesh: trimesh.Trimesh,
    height_mm: float | None = None,
    width_mm: float | None = None,
    depth_mm: float | None = None,
    scale: float | None = None,
) -> trimesh.Trimesh:
    """Escala la malla uniformemente. Exactamente una de estas opciones debe indicarse:
    - height_mm / width_mm / depth_mm: dimensión real conocida del objeto (ejes Z/X/Y,
      asumiendo que la malla ya está orientada con la base hacia -Z según orientation.py).
    - scale: factor de escala relativo directo (si ya se conoce, p.ej. viene de un
      marcador de referencia en la escena).
    """
    given = [v for v in (height_mm, width_mm, depth_mm, scale) if v is not None]
    if len(given) != 1:
        raise ScalingError(
            "Debes indicar exactamente una de: --height-mm, --width-mm, --depth-mm o --scale."
        )

    extents = mesh.extents  # [x, y, z] tamaño actual (unidades arbitrarias de la reconstrucción)
    if scale is not None:
        factor = scale
    elif height_mm is not None:
        if extents[2] <= 0:
            raise ScalingError("La malla no tiene altura (Z) medible.")
        factor = height_mm / extents[2]
    elif width_mm is not None:
        if extents[0] <= 0:
            raise ScalingError("La malla no tiene ancho (X) medible.")
        factor = width_mm / extents[0]
    else:
        if extents[1] <= 0:
            raise ScalingError("La malla no tiene profundidad (Y) medible.")
        factor = depth_mm / extents[1]

    if factor <= 0:
        raise ScalingError(f"Factor de escala inválido: {factor}")

    mesh = mesh.copy()
    mesh.apply_scale(factor)
    return mesh
