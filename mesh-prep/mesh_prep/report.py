"""Genera el reporte JSON final: dimensiones, triángulos, watertight, volumen y peso."""
from __future__ import annotations

import json
from pathlib import Path

import trimesh

PLA_DENSITY_G_CM3 = 1.24


def estimate_weight_g(volume_cm3: float, infill_fraction: float, density_g_cm3: float = PLA_DENSITY_G_CM3) -> float:
    """Estimación simplificada: volumen * densidad * relleno. No modela el perímetro/
    paredes por separado (un slicer real dará un número más preciso), pero sirve como
    aproximación rápida para presupuestar filamento."""
    return volume_cm3 * density_g_cm3 * infill_fraction


def build_report(
    mesh: trimesh.Trimesh,
    infill_fraction: float = 0.2,
    density_g_cm3: float = PLA_DENSITY_G_CM3,
) -> dict:
    extents = mesh.extents  # mm, asumiendo que la malla ya se escaló
    is_watertight = bool(mesh.is_watertight)

    if is_watertight:
        volume_mm3 = abs(float(mesh.volume))
    else:
        # Sin watertight no hay un volumen cerrado fiable; usamos el volumen del
        # convex hull como cota superior aproximada y lo marcamos en el reporte.
        volume_mm3 = abs(float(mesh.convex_hull.volume))

    volume_cm3 = volume_mm3 / 1000.0
    weight_g = estimate_weight_g(volume_cm3, infill_fraction, density_g_cm3)

    return {
        "dimensions_mm": {
            "x": round(float(extents[0]), 2),
            "y": round(float(extents[1]), 2),
            "z": round(float(extents[2]), 2),
        },
        "triangle_count": int(len(mesh.faces)),
        "vertex_count": int(len(mesh.vertices)),
        "is_watertight": is_watertight,
        "is_winding_consistent": bool(mesh.is_winding_consistent),
        "volume_cm3": round(volume_cm3, 3),
        "volume_is_approximate_convex_hull": not is_watertight,
        "estimated_weight_g": {
            "infill_fraction": infill_fraction,
            "material": "PLA+",
            "density_g_cm3": density_g_cm3,
            "weight_g": round(weight_g, 2),
        },
    }


def write_report(report: dict, output_path: Path) -> None:
    output_path = Path(output_path)
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
