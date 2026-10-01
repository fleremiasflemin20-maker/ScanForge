"""Orientación de la pieza: alinear la base con -Z, generar una tapa plana en el
corte de la mesa, y centrar/apoyar la pieza sobre la cama de impresión (Z=0)."""
from __future__ import annotations

import numpy as np
import trimesh

from .plane_removal import SupportPlane


def orient_to_canonical_frame(mesh: trimesh.Trimesh, plane: SupportPlane) -> trimesh.Trimesh:
    """Rota la malla para que `plane.normal` pase a ser +Z, y traslada para que el
    plano de corte quede exactamente en Z=0. Tras esto, el objeto queda "de pie" con
    el hueco de la mesa abierto hacia abajo (Z<=0 no debería tener geometría)."""
    z_axis = np.array([0.0, 0.0, 1.0])
    rotation = trimesh.geometry.align_vectors(plane.normal, z_axis)

    mesh = mesh.copy()
    mesh.apply_transform(rotation)

    # El plano, tras rotar, sigue a `offset` unidades a lo largo de la normal original;
    # como la normal ahora es +Z, basta trasladar en Z para llevarlo a 0.
    rotated_normal = rotation[:3, :3] @ plane.normal
    current_plane_z = plane.offset * np.sign(rotated_normal[2]) if rotated_normal[2] != 0 else plane.offset
    # Forma robusta: tomamos un punto conocido del plano (normal*offset) y lo rotamos.
    point_on_plane = plane.normal * plane.offset
    rotated_point = trimesh.transform_points(point_on_plane.reshape(1, 3), rotation)[0]
    mesh.apply_translation([0.0, 0.0, -rotated_point[2]])

    return mesh


def generate_flat_base(mesh: trimesh.Trimesh, z_tol: float | None = None) -> trimesh.Trimesh:
    """Encuentra el/los borde(s) abierto(s) cerca de Z=0 (dejados por el corte de la
    mesa) y los tapa con un parche plano en Z=0, dando al objeto una base plana para
    la cama de impresión."""
    mesh = mesh.copy()
    if z_tol is None:
        bbox_diag = np.linalg.norm(mesh.bounds[1] - mesh.bounds[0])
        z_tol = max(bbox_diag * 0.02, 1e-4)

    boundary_edges = mesh.edges[trimesh.grouping.group_rows(mesh.edges_sorted, require_count=1)]
    if len(boundary_edges) == 0:
        return mesh  # ya está cerrada, no hay nada que tapar

    loops = _trace_boundary_loops(boundary_edges)

    new_vertices = list(mesh.vertices)
    new_faces = list(mesh.faces)

    for loop in loops:
        loop_points = mesh.vertices[loop]
        if not np.all(np.abs(loop_points[:, 2]) < z_tol * 5):
            continue  # no es el borde de la mesa, es otro hueco; se deja para pymeshlab

        cap_verts, cap_faces = _triangulate_flat_loop(loop_points[:, :2])
        if cap_faces is None or len(cap_faces) == 0:
            continue

        base_index = len(new_vertices)
        z_value = float(np.mean(loop_points[:, 2]))
        for (x, y) in cap_verts:
            new_vertices.append([x, y, z_value])

        # Los primeros len(loop) vértices de cap_verts corresponden 1:1 al loop original
        # (ver _triangulate_flat_loop); el resto son puntos interiores nuevos.
        for face in cap_faces:
            resolved = [
                loop[idx] if idx < len(loop) else base_index + idx
                for idx in face
            ]
            new_faces.append(resolved)

    capped = trimesh.Trimesh(vertices=np.array(new_vertices), faces=np.array(new_faces), process=False)
    capped.merge_vertices()
    capped.update_faces(capped.nondegenerate_faces())
    capped.remove_unreferenced_vertices()
    return capped


def _trace_boundary_loops(boundary_edges: np.ndarray) -> list[np.ndarray]:
    adjacency: dict[int, list[int]] = {}
    for a, b in boundary_edges:
        adjacency.setdefault(int(a), []).append(int(b))
        adjacency.setdefault(int(b), []).append(int(a))

    visited: set[int] = set()
    loops: list[np.ndarray] = []
    for start in adjacency:
        if start in visited:
            continue
        loop = [start]
        visited.add(start)
        current = start
        prev = None
        while True:
            neighbors = [n for n in adjacency[current] if n != prev]
            nxt = next((n for n in neighbors if n not in visited), None)
            if nxt is None:
                break
            loop.append(nxt)
            visited.add(nxt)
            prev, current = current, nxt
        if len(loop) >= 3:
            loops.append(np.array(loop))
    return loops


def _triangulate_flat_loop(points_2d: np.ndarray):
    """Triangula un polígono cerrado 2D. Devuelve (vertices_2d, faces) donde los
    primeros `len(points_2d)` vértices de salida coinciden en orden con la entrada."""
    try:
        from shapely.geometry import Polygon

        from trimesh.creation import triangulate_polygon

        polygon = Polygon(points_2d)
        if not polygon.is_valid:
            polygon = polygon.buffer(0)
        if polygon.is_empty:
            return points_2d, None
        verts, faces = triangulate_polygon(polygon)
        return verts, faces
    except Exception:
        # Fallback: triangulación en abanico desde el centroide (asume forma ~convexa).
        centroid = points_2d.mean(axis=0)
        n = len(points_2d)
        verts = np.vstack([points_2d, centroid])
        center_idx = n
        faces = [[i, (i + 1) % n, center_idx] for i in range(n)]
        return verts, np.array(faces)


def center_and_drop_to_bed(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    """Centra la pieza en X/Y respecto al origen y apoya su punto más bajo en Z=0."""
    mesh = mesh.copy()
    bounds = mesh.bounds
    center_xy = (bounds[0][:2] + bounds[1][:2]) / 2.0
    min_z = bounds[0][2]
    mesh.apply_translation([-center_xy[0], -center_xy[1], -min_z])
    return mesh
