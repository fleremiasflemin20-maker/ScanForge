"""Detección y corte del plano de mesa/soporte que queda incluido en el escaneo.

La idea: el objeto fue escaneado apoyado sobre una superficie plana (mesa, tornamesa,
tapete). Esa superficie suele reconstruirse como la región plana de mayor área
contigua de toda la malla, y se encuentra en uno de los extremos de la nube de puntos
a lo largo de la normal de ese plano (el objeto está "encima"). Buscamos esa región
agrupando caras por (normal, desplazamiento) y cortamos todo lo que quede en o más
allá del plano encontrado.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import trimesh


@dataclass
class SupportPlane:
    normal: np.ndarray  # normal unitaria, apunta HACIA el objeto (lejos de la mesa)
    offset: float  # d tal que normal · punto == offset define el plano de corte
    face_area_fraction: float  # fracción del área total de la malla que representa


def detect_support_plane(
    mesh: trimesh.Trimesh,
    normal_angle_tol_deg: float = 4.0,
    min_area_fraction: float = 0.04,
    extreme_percentile: float = 0.15,
) -> SupportPlane | None:
    """Devuelve el plano de soporte detectado, o None si no hay una región plana
    suficientemente grande y extrema como para ser la mesa (p.ej. si el objeto se
    capturó ya aislado con --object-masking y no hay mesa en la malla)."""
    face_normals = mesh.face_normals
    face_areas = mesh.area_faces
    centroids = mesh.triangles_center
    total_area = face_areas.sum()
    if total_area <= 0:
        return None

    # Bucket por dirección de normal (cuantizada) + desplazamiento al plano, para
    # agrupar caras aproximadamente coplanares sin un RANSAC iterativo costoso.
    angle_bins = max(8, int(180 / normal_angle_tol_deg))
    bbox_diag = np.linalg.norm(mesh.bounds[1] - mesh.bounds[0])
    dist_bin_size = max(bbox_diag / 1000.0, 1e-6)

    # Canonicaliza el signo de la normal (evita duplicar el mismo plano en dos buckets
    # opuestos): forzamos que la componente de mayor magnitud sea positiva.
    normals = face_normals.copy()
    flip = normals[np.arange(len(normals)), np.argmax(np.abs(normals), axis=1)] < 0
    normals[flip] *= -1

    quantized_normal = np.round(normals * angle_bins).astype(np.int64)
    offsets = np.einsum("ij,ij->i", centroids, normals)
    quantized_offset = np.round(offsets / dist_bin_size).astype(np.int64)

    keys = [
        (qn[0], qn[1], qn[2], qo)
        for qn, qo in zip(quantized_normal, quantized_offset)
    ]

    groups: dict[tuple, list[int]] = {}
    for i, key in enumerate(keys):
        groups.setdefault(key, []).append(i)

    group_items = []
    for key, idxs in groups.items():
        idxs_arr = np.array(idxs)
        area = face_areas[idxs_arr].sum()
        if area / total_area < min_area_fraction:
            continue
        mean_normal = normals[idxs_arr].mean(axis=0)
        mean_normal /= np.linalg.norm(mean_normal)
        mean_offset = offsets[idxs_arr].mean()
        group_items.append((area, mean_normal, mean_offset, idxs_arr))

    if not group_items:
        return None

    group_items.sort(key=lambda g: g[0], reverse=True)

    for area, mean_normal, mean_offset, _idxs in group_items:
        proj = centroids @ mean_normal
        lo, hi = np.percentile(proj, [0, 100])
        span = max(hi - lo, 1e-9)
        pos_in_range = (mean_offset - lo) / span  # 0 = extremo bajo, 1 = extremo alto

        if pos_in_range <= extreme_percentile:
            sign = 1.0  # el objeto está en la dirección +normal
        elif pos_in_range >= 1.0 - extreme_percentile:
            sign = -1.0  # el objeto está en la dirección -normal
        else:
            continue  # este plano está "en medio", no es un candidato a mesa

        up_normal = mean_normal * sign
        up_offset = mean_offset * sign  # up_normal · punto == up_offset en el plano

        return SupportPlane(
            normal=up_normal,
            offset=float(up_offset),
            face_area_fraction=float(area / total_area),
        )

    return None


def cut_support_plane(
    mesh: trimesh.Trimesh,
    plane: SupportPlane,
    margin_fraction: float = 0.01,
) -> trimesh.Trimesh:
    """Elimina todas las caras en el lado de la mesa (y la propia mesa), dejando solo
    las caras del objeto por encima del plano de corte."""
    bbox_diag = np.linalg.norm(mesh.bounds[1] - mesh.bounds[0])
    margin = max(bbox_diag * margin_fraction, 1e-6)

    centroids = mesh.triangles_center
    signed = centroids @ plane.normal - plane.offset
    keep_mask = signed > margin

    if not keep_mask.any():
        raise ValueError("El corte del plano de mesa eliminó toda la malla; revisa la detección del plano.")

    new_mesh = mesh.submesh([keep_mask], append=True, repair=False)
    return new_mesh
