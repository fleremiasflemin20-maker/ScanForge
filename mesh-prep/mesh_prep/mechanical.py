"""Modo pieza mecánica: ingeniería inversa ligera para piezas técnicas (soportes,
piezas de auto, carcasas). Un escaneo óptico redondea las aristas y deja las caras
planas onduladas por el ruido; en una pieza mecánica casi todo son planos (paredes de
ranuras, asientos, bridas, caras de apoyo), así que:

1. Se segmenta la malla en regiones de normal casi constante (crecimiento de regiones).
2. A cada región grande se le ajusta un plano por mínimos cuadrados.
3. Los vértices de la región que están cerca de ese plano se proyectan sobre él.

Las caras quedan perfectamente planas y, como dos planos vecinos se cortan en una
recta, las aristas de las ranuras y encajes vuelven a ser vivas. Las zonas curvas
(agujeros, redondeos) no forman regiones planas y no se tocan.
"""
from __future__ import annotations

from collections import deque

import numpy as np
import trimesh


def planar_regions(mesh: trimesh.Trimesh, angle_deg: float = 8.0,
                   min_area_fraction: float = 0.002) -> list[np.ndarray]:
    """Regiones de caras conectadas cuya normal no se aparta más de `angle_deg` de la
    normal media de la región. Devuelve los índices de caras de cada región grande.

    Las normales se miden en una copia suavizada (Taubin, no encoge la pieza): en un
    escaneo real cada triángulo está inclinado por el ruido y, sin suavizar, ninguna
    cara plana se reconocería como tal."""
    smooth = mesh.copy()
    trimesh.smoothing.filter_taubin(smooth, iterations=15)
    normals = smooth.face_normals
    areas = mesh.area_faces
    adjacency = [[] for _ in range(len(mesh.faces))]
    for a, b in mesh.face_adjacency:
        adjacency[a].append(b)
        adjacency[b].append(a)

    cos_limit = np.cos(np.radians(angle_deg))
    min_area = mesh.area * min_area_fraction
    visited = np.zeros(len(mesh.faces), dtype=bool)
    regions = []
    for seed in np.argsort(-areas):  # empezar por caras grandes da regiones más limpias
        if visited[seed]:
            continue
        region = [seed]
        visited[seed] = True
        normal_sum = normals[seed] * areas[seed]
        queue = deque([seed])
        while queue:
            f = queue.popleft()
            mean = normal_sum / np.linalg.norm(normal_sum)
            for g in adjacency[f]:
                if not visited[g] and normals[g] @ mean >= cos_limit:
                    visited[g] = True
                    region.append(g)
                    normal_sum = normal_sum + normals[g] * areas[g]
                    queue.append(g)
        region = np.array(region)
        if areas[region].sum() >= min_area:
            regions.append(region)
    return regions


def flatten_planar_faces(mesh: trimesh.Trimesh, angle_deg: float = 8.0,
                         tolerance: float | None = None) -> tuple[trimesh.Trimesh, int]:
    """Proyecta cada región plana sobre su plano ajustado. `tolerance` (unidades de la
    malla) limita cuánto puede moverse un vértice; por defecto 1,5 aristas medias, que
    cubre el ruido del escaneo sin aplastar detalles reales. Devuelve (malla, nº de
    planos aplicados)."""
    mesh = mesh.copy()
    if tolerance is None:
        tolerance = float(np.median(mesh.edges_unique_length)) * 1.5
    vertices = mesh.vertices.copy()
    # Un vértice en la arista entre dos planos se mueve a la intersección: se acumulan
    # las proyecciones y se promedian (para dos planos eso cae sobre la arista).
    moved = np.zeros_like(vertices)
    count = np.zeros(len(vertices))
    applied = 0
    planes: list[tuple[np.ndarray, np.ndarray, np.ndarray, float]] = []
    for region in planar_regions(mesh, angle_deg):
        idx = np.unique(mesh.faces[region])
        pts = vertices[idx]
        center = pts.mean(axis=0)
        _, _, axes = np.linalg.svd(pts - center, full_matrices=False)
        normal = axes[2]
        if normal @ mesh.face_normals[region].mean(axis=0) < 0:
            normal = -normal  # hacia fuera de la pieza
        dist = (pts - center) @ normal
        # El ruido real de esta cara (desviación robusta): todo lo que esté dentro de
        # 4 sigmas es ruido del escaneo, no un detalle de la pieza.
        sigma = 1.4826 * float(np.median(np.abs(dist)))
        near = np.abs(dist) <= max(tolerance, 4.0 * sigma)
        if near.sum() < 3:
            continue
        applied += 1
        moved[idx[near]] += pts[near] - dist[near, None] * normal
        count[idx[near]] += 1
        planes.append((idx, center, normal, max(tolerance, 4.0 * sigma)))
    touched = count > 0
    vertices[touched] = moved[touched] / count[touched, None]

    # Recorte de picos: en las aristas quedan vértices sueltos que sobresalen hacia
    # fuera de una cara plana vecina (inflan las medidas). Se recortan al plano, como
    # lo haría un calibre apoyado en la cara; las hendiduras hacia dentro no se tocan.
    neighbors = mesh.vertex_neighbors
    for idx, center, normal, tol in planes:
        ring = set(idx.tolist())
        for _ in range(2):
            ring |= {n for v in list(ring) for n in neighbors[v]}
        ring_idx = np.fromiter(ring, dtype=np.int64)
        out = (vertices[ring_idx] - center) @ normal
        spike = (out > 0) & (out <= tol * 8)
        if spike.any():
            vertices[ring_idx[spike]] -= out[spike, None] * normal
    mesh.vertices = vertices
    return mesh, applied
