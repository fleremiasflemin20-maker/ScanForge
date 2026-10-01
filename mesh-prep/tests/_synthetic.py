"""Genera mallas sintéticas 'objeto sobre mesa' para probar el pipeline sin datos
reales de fotogrametría."""
from __future__ import annotations

import numpy as np
import trimesh


def build_object_on_table(radius: float = 50.0, cut_z: float = -20.0, table_radius: float = 300.0) -> trimesh.Trimesh:
    """Media esfera (el "objeto") soldada a un anillo plano grande (la "mesa"),
    con un pequeño agujero de ruido en el objeto y un fragmento suelto lejano."""
    sphere = trimesh.creation.icosphere(subdivisions=4, radius=radius)
    centroids = sphere.triangles_center
    keep = centroids[:, 2] > cut_z
    cap = sphere.submesh([keep], append=True, repair=False)

    boundary_idx = trimesh.grouping.group_rows(cap.edges_sorted, require_count=1)
    boundary_edges = cap.edges_sorted[boundary_idx.reshape(-1)]
    loop_vertex_ids = np.unique(boundary_edges.reshape(-1))
    loop_points = cap.vertices[loop_vertex_ids]

    angles = np.arctan2(loop_points[:, 1], loop_points[:, 0])
    order = np.argsort(angles)
    ring_inner = loop_points[order]
    n = len(ring_inner)
    theta = np.linspace(0, 2 * np.pi, n, endpoint=False)
    ring_outer = np.stack(
        [table_radius * np.cos(theta), table_radius * np.sin(theta), np.full(n, cut_z)], axis=1
    )

    table_verts = np.vstack([ring_inner, ring_outer])
    faces = []
    for i in range(n):
        i2 = (i + 1) % n
        faces.append([i, i2, n + i2])
        faces.append([i, n + i2, n + i])
    table = trimesh.Trimesh(vertices=table_verts, faces=np.array(faces), process=False)

    combined = trimesh.util.concatenate([cap, table])
    combined.merge_vertices()
    combined.update_faces(combined.nondegenerate_faces())
    combined.remove_unreferenced_vertices()

    # Agujero de ruido en el cuerpo del objeto (lejos del corte de la mesa).
    centroids2 = combined.triangles_center
    candidate_faces = np.where(centroids2[:, 2] > 10)[0]
    hole_face = candidate_faces[len(candidate_faces) // 2]
    keep_mask = np.ones(len(combined.faces), dtype=bool)
    keep_mask[hole_face] = False
    combined = combined.submesh([keep_mask], append=True, repair=False)

    # Fragmento suelto lejano (ruido de reconstrucción).
    noise = trimesh.creation.icosphere(subdivisions=1, radius=1.0)
    noise.apply_translation([500, 500, 500])
    combined = trimesh.util.concatenate([combined, noise])

    return combined


def build_isolated_object(radius: float = 25.0) -> trimesh.Trimesh:
    """Un objeto ya aislado (sin mesa), como si se hubiera capturado con object-masking."""
    return trimesh.creation.icosphere(subdivisions=3, radius=radius)
