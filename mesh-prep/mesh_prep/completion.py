"""Completado de piezas: lo mismo que hacen los programas de los escáneres comerciales
(Creality Scan, Revo Scan, Artec Studio) después de escanear.

- `denoise`: suavizado que conserva aristas vivas (quita el "granulado" del escaneo sin
  redondear cantos).
- `detect_mirror_symmetry` + `symmetry_fill_points`: si la pieza es simétrica, refleja
  la mitad bien escaneada para reconstruir la zona que no se vio (debajo, huecos).
- `complete_watertight`: Poisson "screened" sobre la superficie muestreada; rellena los
  agujeros siguiendo la curvatura y deja una malla cerrada (watertight). Después los
  vértices que caen sobre zonas escaneadas se proyectan a la superficie original, así
  el detalle medido no se pierde: solo se inventa geometría donde no había datos.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pymeshlab as pml
import trimesh
from scipy.optimize import minimize
from scipy.spatial import cKDTree

from .cleanup import keep_largest_component


@dataclass
class SymmetryPlane:
    normal: np.ndarray
    offset: float  # plano: dot(normal, x) == offset
    score: float  # error tras reflejar / error de muestreo (1.0 = simetría perfecta)

    def reflect(self, points: np.ndarray) -> np.ndarray:
        d = points @ self.normal - self.offset
        return points - 2.0 * d[:, None] * self.normal[None, :]

    def reflect_normals(self, normals: np.ndarray) -> np.ndarray:
        return normals - 2.0 * (normals @ self.normal)[:, None] * self.normal[None, :]


def _to_meshset(mesh: trimesh.Trimesh) -> pml.MeshSet:
    ms = pml.MeshSet()
    ms.add_mesh(pml.Mesh(vertex_matrix=np.asarray(mesh.vertices, dtype=np.float64),
                         face_matrix=np.asarray(mesh.faces, dtype=np.int32)))
    return ms


def _from_meshset(ms: pml.MeshSet) -> trimesh.Trimesh:
    m = ms.current_mesh()
    return trimesh.Trimesh(vertices=m.vertex_matrix(), faces=m.face_matrix(), process=True)


def _median_edge(mesh: trimesh.Trimesh) -> float:
    lengths = mesh.edges_unique_length
    return float(np.median(lengths)) if len(lengths) else 0.0


def denoise(mesh: trimesh.Trimesh, iterations: int = 3) -> trimesh.Trimesh:
    """Suavizado en dos pasos (normales y luego posiciones) que respeta aristas por
    encima de ~60°: elimina el ruido de alta frecuencia sin "derretir" la pieza."""
    ms = _to_meshset(mesh)
    ms.apply_coord_two_steps_smoothing(stepsmoothnum=iterations, normalthr=60, stepnormalnum=20, stepfitnum=20)
    return _from_meshset(ms)


def _sample_surface(mesh: trimesh.Trimesh, count: int) -> tuple[np.ndarray, np.ndarray]:
    points, face_index = trimesh.sample.sample_surface_even(mesh, count)
    if len(points) < count // 4:  # sample_surface_even descarta mucho en mallas raras
        points, face_index = trimesh.sample.sample_surface(mesh, count)
    return np.asarray(points), np.asarray(mesh.face_normals[face_index])


@dataclass
class HoleRegion:
    """Zona sin datos: el contorno del agujero proyectado en su plano medio, más una
    profundidad a cada lado (lo que la pieza tendría "dentro" del agujero)."""
    center: np.ndarray
    normal: np.ndarray
    basis: np.ndarray  # 2x3: ejes u, v del plano
    polygon: object  # shapely Polygon en coordenadas (u, v)
    depth: float

    def contains(self, points: np.ndarray) -> np.ndarray:
        import shapely

        rel = points - self.center
        uv = rel @ self.basis.T
        near_plane = np.abs(rel @ self.normal) <= self.depth
        return near_plane & shapely.contains_xy(self.polygon, uv[:, 0], uv[:, 1])


def _hole_regions(mesh: trimesh.Trimesh) -> list[HoleRegion]:
    from shapely.geometry import Polygon

    from .orientation import _trace_boundary_loops

    boundary = mesh.edges[trimesh.grouping.group_rows(mesh.edges_sorted, require_count=1)]
    regions = []
    for loop in _trace_boundary_loops(boundary) if len(boundary) else []:
        pts = mesh.vertices[loop]
        center = pts.mean(axis=0)
        _, _, axes = np.linalg.svd(pts - center, full_matrices=False)
        basis, normal = axes[:2], axes[2]
        polygon = Polygon((pts - center) @ basis.T).buffer(0)
        if polygon.is_empty or polygon.area <= 0:
            continue
        radius = float(np.sqrt(polygon.area / np.pi))
        regions.append(HoleRegion(center, normal, basis, polygon.buffer(radius * 0.1), radius * 0.8))
    return regions


def _in_holes(points: np.ndarray, regions: list[HoleRegion]) -> np.ndarray:
    inside = np.zeros(len(points), dtype=bool)
    for region in regions:
        inside |= region.contains(points)
    return inside


def detect_mirror_symmetry(mesh: trimesh.Trimesh, max_score: float = 1.6,
                           samples: int = 6000) -> SymmetryPlane | None:
    """Busca un plano de simetría especular. Parte de los tres ejes principales (PCA)
    y afina cada uno minimizando la distancia entre la pieza y su reflejo. Los puntos
    cuyo reflejo cae dentro de un agujero no cuentan (ahí faltan datos, no es
    asimetría); todos los demás sí, así un detalle asimétrico pequeño basta para
    rechazar el plano. Devuelve None si la pieza no es claramente simétrica."""
    points, _ = _sample_surface(mesh, samples)
    if len(points) < 100:
        return None
    diag = float(np.linalg.norm(mesh.extents))
    dense, _ = _sample_surface(mesh, samples * 8)
    tree = cKDTree(dense)
    holes = _hole_regions(mesh)
    center = points.mean(axis=0)
    _, _, axes = np.linalg.svd(points - center, full_matrices=False)
    cap = diag * 0.05
    # Distancia de muestreo: lo que mide una pieza perfecta contra sí misma.
    noise = float(tree.query(_sample_surface(mesh, samples)[0])[0].mean())

    def plane_from(params: np.ndarray) -> SymmetryPlane:
        theta, phi, d = params
        n = np.array([np.sin(theta) * np.cos(phi), np.sin(theta) * np.sin(phi), np.cos(theta)])
        return SymmetryPlane(normal=n, offset=float(n @ center + d * diag), score=0.0)

    def cost(params: np.ndarray) -> float:
        mirrored = plane_from(params).reflect(points)
        counted = ~_in_holes(mirrored, holes)
        if counted.sum() < len(points) * 0.5:
            return cap
        dist, _ = tree.query(mirrored[counted])
        return float(np.minimum(dist, cap).mean())

    best: SymmetryPlane | None = None
    for axis in axes:
        theta0 = float(np.arccos(np.clip(axis[2], -1, 1)))
        phi0 = float(np.arctan2(axis[1], axis[0]))
        # Dos arranques por eje: por el centroide y por el centro de la caja (si falta
        # un trozo grande, el centroide se desplaza hacia el lado que sí se escaneó).
        for d0 in {0.0, float((mesh.bounds.mean(axis=0) - center) @ axis) / diag}:
            x0 = np.array([theta0, phi0, d0])
            simplex = np.array([x0, x0 + [0.08, 0, 0], x0 + [0, 0.08, 0], x0 + [0, 0, 0.03]])
            result = minimize(cost, x0=x0, method="Nelder-Mead",
                              options={"initial_simplex": simplex, "xatol": 1e-4, "fatol": 1e-7, "maxiter": 400})
            plane = plane_from(result.x)
            plane.score = float(result.fun) / max(noise, 1e-12)
            if best is None or plane.score < best.score:
                best = plane
    if best is None or best.score > max_score:
        return None
    return best


def symmetry_fill_points(mesh: trimesh.Trimesh, plane: SymmetryPlane,
                         samples: int = 150_000) -> tuple[np.ndarray, np.ndarray]:
    """Puntos del reflejo que caen dentro de un agujero y donde la pieza no tiene
    superficie: son exactamente las partes que faltan. Lo ya escaneado no se toca."""
    points, normals = _sample_surface(mesh, samples)
    mirrored = plane.reflect(points)
    mirrored_normals = plane.reflect_normals(normals)
    dist, _ = cKDTree(points).query(mirrored)
    gap = max(_median_edge(mesh) * 3.0, float(np.linalg.norm(mesh.extents)) * 0.004)
    missing = (dist > gap) & _in_holes(mirrored, _hole_regions(mesh))
    return mirrored[missing], mirrored_normals[missing]


def _poisson_worker(points, normals, depth, samples_per_node, queue) -> None:
    from mesh_prep import _ensure_meshlab_plugins

    _ensure_meshlab_plugins()
    ms = pml.MeshSet()
    ms.add_mesh(pml.Mesh(vertex_matrix=points, v_normals_matrix=normals))
    ms.generate_surface_reconstruction_screened_poisson(
        depth=depth, pointweight=4.0, samplespernode=samples_per_node, preclean=True
    )
    m = ms.current_mesh()
    queue.put((m.vertex_matrix(), m.face_matrix()))


def _poisson_isolated(points: np.ndarray, normals: np.ndarray, depth: int,
                      samples_per_node: float) -> tuple[np.ndarray, np.ndarray] | None:
    """PoissonRecon termina el proceso entero (exit) cuando falla en casos raros
    ("Failed to close loop"). Se ejecuta en un proceso hijo para poder reintentar."""
    import multiprocessing as mp
    import queue as queue_module

    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    proc = ctx.Process(target=_poisson_worker, args=(points.astype(np.float64), normals.astype(np.float64),
                                                     depth, samples_per_node, q))
    proc.start()
    vertices = faces = None
    while True:
        try:
            vertices, faces = q.get(timeout=1.0)
            break
        except queue_module.Empty:
            if not proc.is_alive():  # PoissonRecon hizo exit(): no habrá resultado
                break
    proc.join(timeout=10)
    if proc.is_alive():
        proc.kill()
    if vertices is None or len(faces) == 0:
        return None
    return vertices, faces


def _auto_depth(mesh: trimesh.Trimesh) -> int:
    """Profundidad del octree de Poisson para que la celda sea ~la mitad de la arista
    media de la malla (resolución equivalente a la del escaneo)."""
    edge = _median_edge(mesh)
    size = float(mesh.extents.max())
    if edge <= 0 or size <= 0:
        return 9
    return int(np.clip(np.ceil(np.log2(size / (edge * 0.5))), 8, 11))


def complete_watertight(mesh: trimesh.Trimesh, extra_points: np.ndarray | None = None,
                        extra_normals: np.ndarray | None = None, depth: int | None = None,
                        samples: int = 300_000) -> trimesh.Trimesh:
    """Rellena todos los huecos y devuelve una malla cerrada conservando el detalle
    escaneado (ver docstring del módulo)."""
    def oriented_points() -> tuple[np.ndarray, np.ndarray]:
        pts, nrm = _sample_surface(mesh, samples)
        if extra_points is not None and len(extra_points):
            pts = np.vstack([pts, extra_points])
            nrm = np.vstack([nrm, extra_normals])
        # Normales nulas/NaN (caras degeneradas) hacen fallar a PoissonRecon.
        valid = np.isfinite(pts).all(axis=1) & (np.linalg.norm(nrm, axis=1) > 0.5)
        return pts[valid], nrm[valid]

    depth = depth or _auto_depth(mesh)
    result = None
    # El fallo raro de PoissonRecon depende de la nube concreta: cada reintento usa
    # un muestreo nuevo además de otros parámetros.
    for attempt_depth, attempt_samples in ((depth, 1.5), (depth, 3.0), (depth, 1.5), (max(depth - 1, 6), 3.0)):
        points, normals = oriented_points()
        result = _poisson_isolated(points, normals, attempt_depth, attempt_samples)
        if result is not None:
            break
    if result is None:
        raise RuntimeError("La reconstrucción Poisson falló en todos los intentos.")
    completed = keep_largest_component(trimesh.Trimesh(vertices=result[0], faces=result[1], process=True))

    # Transferencia de detalle: donde había datos, el vértice vuelve a la superficie
    # medida (proyección sobre el plano del triángulo original más cercano).
    centroids = mesh.triangles_center
    face_normals = mesh.face_normals
    dist, idx = cKDTree(centroids).query(completed.vertices)
    tol = max(_median_edge(mesh) * 2.0, 1e-9)
    near = dist < tol
    v = completed.vertices.copy()
    offsets = np.einsum("ij,ij->i", v[near] - centroids[idx[near]], face_normals[idx[near]])
    v[near] -= offsets[:, None] * face_normals[idx[near]]
    completed = trimesh.Trimesh(vertices=v, faces=completed.faces, process=True)

    if not completed.is_watertight:
        ms = _to_meshset(completed)
        ms.meshing_remove_duplicate_faces()
        ms.meshing_repair_non_manifold_edges()
        ms.meshing_close_holes(maxholesize=100, selfintersection=False)
        completed = _from_meshset(ms)
    completed.fix_normals()
    return completed
