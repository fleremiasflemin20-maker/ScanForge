"""Validación de precisión al estilo VDI/VDE 2634 parte 2 (lo que usan Shining 3D,
Creality o Revopoint para publicar su precisión), con artefactos caseros:

- **Esfera** (bola de rodamiento mateada, Ø conocido): error de palpado de forma
  (PF, rango de residuos radiales) y de tamaño (PS, Ø medido − Ø real).
- **Barra de dos esferas** (distancia entre centros conocida): error de distancia (SD).
- **Plano** (vidrio float o bloque patrón): planitud (F, rango de residuos al plano).

Como permite la norma, se descartan los 3 de cada 1000 puntos más alejados antes de
calcular rangos. Uso:

    python -m mesh_prep.validate --mesh escaneo.stl --sphere 25.4
    python -m mesh_prep.validate --mesh barra.stl --sphere 25.4 --spacing 100
    python -m mesh_prep.validate --mesh vidrio.stl --plane
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass

import numpy as np
import trimesh
from scipy.optimize import least_squares

# VDI/VDE 2634-2: se pueden excluir como máximo 3 de cada 1000 puntos.
OUTLIER_FRACTION = 0.003


@dataclass
class SphereFit:
    center: list[float]
    diameter: float
    form_error: float  # PF: rango de residuos radiales (mm)
    size_error: float | None  # PS: Ø medido − Ø nominal (mm)
    points: int


@dataclass
class PlaneFit:
    normal: list[float]
    flatness: float  # F: rango de residuos al plano (mm)
    rms: float
    points: int


def _trim_range(residuals: np.ndarray) -> float:
    keep = int(np.ceil(len(residuals) * (1 - OUTLIER_FRACTION)))
    order = np.argsort(np.abs(residuals - np.median(residuals)))[:keep]
    r = residuals[order]
    return float(r.max() - r.min())


def fit_sphere(points: np.ndarray) -> tuple[np.ndarray, float]:
    """Ajuste algebraico (lineal) refinado por mínimos cuadrados geométricos."""
    a = np.hstack([2 * points, np.ones((len(points), 1))])
    b = (points ** 2).sum(axis=1)
    sol, *_ = np.linalg.lstsq(a, b, rcond=None)
    center = sol[:3]
    radius = np.sqrt(sol[3] + center @ center)

    def residuals(p):
        return np.linalg.norm(points - p[:3], axis=1) - p[3]

    result = least_squares(residuals, np.append(center, radius), loss="soft_l1")
    return result.x[:3], float(abs(result.x[3]))


def find_spheres(points: np.ndarray, nominal_diameter: float, count: int,
                 iterations: int = 3000, seed: int = 0) -> list[np.ndarray]:
    """RANSAC de esferas de Ø conocido: devuelve los puntos de cada esfera hallada
    (de mayor a menor soporte). Sirve para la barra o varias bolas en la escena."""
    rng = np.random.default_rng(seed)
    radius = nominal_diameter / 2
    tol = max(radius * 0.04, 0.05)
    remaining = points.copy()
    found = []
    for _ in range(count):
        best_inliers = None
        for _ in range(iterations):
            sample = remaining[rng.choice(len(remaining), 4, replace=False)]
            try:
                center, r = _sphere_from_4(sample)
            except np.linalg.LinAlgError:
                continue
            if r is None or abs(r - radius) > radius * 0.15:
                continue
            dist = np.abs(np.linalg.norm(remaining - center, axis=1) - radius)
            inliers = dist < tol
            if best_inliers is None or inliers.sum() > best_inliers.sum():
                best_inliers = inliers
        if best_inliers is None or best_inliers.sum() < 50:
            break
        # Re-ajuste y recogida final con tolerancia algo mayor (el ruido del escaneo).
        center, r = fit_sphere(remaining[best_inliers])
        dist = np.abs(np.linalg.norm(remaining - center, axis=1) - r)
        member = dist < tol * 2.5
        found.append(remaining[member])
        remaining = remaining[~member]
        if len(remaining) < 50:
            break
    return found


def _sphere_from_4(p: np.ndarray) -> tuple[np.ndarray, float | None]:
    a = 2 * (p[1:] - p[0])
    b = (p[1:] ** 2).sum(axis=1) - (p[0] ** 2).sum()
    center = np.linalg.solve(a, b)
    return center, float(np.linalg.norm(p[0] - center))


def measure_sphere(points: np.ndarray, nominal_diameter: float | None) -> SphereFit:
    center, radius = fit_sphere(points)
    residuals = np.linalg.norm(points - center, axis=1) - radius
    return SphereFit(
        center=[round(float(c), 4) for c in center],
        diameter=round(2 * radius, 4),
        form_error=round(_trim_range(residuals), 4),
        size_error=None if nominal_diameter is None else round(2 * radius - nominal_diameter, 4),
        points=len(points),
    )


def measure_plane(points: np.ndarray) -> PlaneFit:
    center = points.mean(axis=0)
    _, _, axes = np.linalg.svd(points - center, full_matrices=False)
    normal = axes[2]
    residuals = (points - center) @ normal
    return PlaneFit(
        normal=[round(float(n), 5) for n in normal],
        flatness=round(_trim_range(residuals), 4),
        rms=round(float(np.sqrt((residuals ** 2).mean())), 4),
        points=len(points),
    )


def largest_plane_points(mesh: trimesh.Trimesh) -> np.ndarray:
    """Vértices de la mayor cara plana (el vidrio o la cara del bloque patrón)."""
    from .mechanical import planar_regions

    regions = planar_regions(mesh, angle_deg=5.0)
    if not regions:
        return mesh.vertices
    biggest = max(regions, key=lambda r: mesh.area_faces[r].sum())
    return mesh.vertices[np.unique(mesh.faces[biggest])]


def _surface_points(mesh: trimesh.Trimesh, count: int = 60_000) -> np.ndarray:
    points, _ = trimesh.sample.sample_surface(mesh, count, seed=0)
    return np.asarray(points)


def validate(mesh: trimesh.Trimesh, sphere_diameter: float | None = None,
             spacing: float | None = None, plane: bool = False) -> dict:
    report: dict = {"norma": "VDI/VDE 2634-2 (adaptada, artefactos caseros)", "unidades": "mm"}
    if sphere_diameter is not None:
        count = 2 if spacing is not None else 1
        spheres = find_spheres(_surface_points(mesh), sphere_diameter, count)
        if not spheres:
            raise ValueError(f"No se encontró ninguna esfera de Ø{sphere_diameter} mm en la malla.")
        fits = [measure_sphere(s, sphere_diameter) for s in spheres]
        report["esferas"] = [asdict(f) for f in fits]
        report["PF_error_forma"] = max(f.form_error for f in fits)
        report["PS_error_tamano"] = max((f.size_error for f in fits), key=abs)
        if spacing is not None:
            if len(fits) < 2:
                raise ValueError("Se pidió --spacing pero solo se encontró una esfera.")
            distance = float(np.linalg.norm(np.subtract(fits[0].center, fits[1].center)))
            report["distancia_medida"] = round(distance, 4)
            report["SD_error_distancia"] = round(distance - spacing, 4)
    if plane:
        fit = measure_plane(largest_plane_points(mesh))
        report["plano"] = asdict(fit)
        report["F_planitud"] = fit.flatness
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="scanforge-validate", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mesh", required=True, help="STL/OBJ/PLY del escaneo del artefacto (en mm).")
    parser.add_argument("--sphere", type=float, help="Ø nominal de la(s) esfera(s) en mm.")
    parser.add_argument("--spacing", type=float, help="Distancia nominal entre centros de las 2 esferas (barra).")
    parser.add_argument("--plane", action="store_true", help="Medir la planitud de la mayor cara plana.")
    parser.add_argument("--json", help="Guardar el informe en este archivo.")
    args = parser.parse_args(argv)
    if args.sphere is None and not args.plane:
        parser.error("Indica --sphere y/o --plane.")

    mesh = trimesh.load(args.mesh, force="mesh")
    try:
        report = validate(mesh, args.sphere, args.spacing, args.plane)
    except ValueError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1

    labels = {"PF_error_forma": "Error de forma (PF)", "PS_error_tamano": "Error de tamaño (PS)",
              "SD_error_distancia": "Error de distancia (SD)", "F_planitud": "Planitud (F)"}
    print("Precisión medida (VDI/VDE 2634-2 adaptada):")
    for key, label in labels.items():
        if key in report:
            print(f"  {label:26s} {report[key]:+.3f} mm")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
