"""División en partes: cortes limpios (sólidos cerrados de un cuerpo cuya suma es la
pieza), cero solapes entre partes y encajes con la holgura pedida."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import trimesh

from mesh_prep import parts as P
from mesh_prep.pipeline import PipelineOptions, run_pipeline

from ._figure import HAIR, SHIRT, SKIN, colored_figure, figure


def _max_overlap(pieces: list[P.Part]) -> float:
    solids = [P.to_manifold(p.mesh) for p in pieces]
    return max((solids[i] ^ solids[j]).volume() for i in range(len(solids)) for j in range(i + 1, len(solids)))


@pytest.fixture(scope="module")
def shape_parts():
    return P.divide(figure(), by="shape", max_parts=8, connector="pivote", log=lambda *_: None)


def test_shape_split_finds_anatomy_with_clean_planar_cuts(shape_parts):
    # Torso (con el cuello, demasiado corto para ir aparte), cabeza y dos brazos.
    assert len(shape_parts) == 4
    for part in shape_parts:
        assert part.mesh.is_watertight
        assert part.bodies == 1
    planes = [p.plane for p in shape_parts if p.plane is not None]
    normals = np.abs(np.array([n for _, n in planes]))
    # Cortes rectos: hombros en X, cabeza en Z, en la sección más estrecha.
    assert sorted(np.argmax(normals, axis=1).tolist()) == [0, 0, 2]
    assert (normals.max(axis=1) > 0.99).all()
    centers = {int(np.argmax(np.abs(n))): c for c, n in planes}
    assert 15.0 <= abs(centers[0][0]) <= 18.0  # hombro: justo fuera del torso (x = ±15)


def test_shape_split_parts_fit_without_overlap(shape_parts):
    assert _max_overlap(shape_parts) < 1e-3
    assert all("pivote hexagonal" in p.notes[-1] for p in shape_parts if p.plane is not None)
    # La suma es la figura menos los huecos de holgura de los agujeros.
    original = figure().volume
    total = sum(p.mesh.volume for p in shape_parts)
    assert 0 < original - total < original * 0.01


def test_color_split_follows_the_colors():
    mesh = colored_figure()
    labels, palette = P.segment_by_color(mesh, 3)
    found = sorted(palette.tolist())
    for expected in (SKIN, HAIR, SHIRT):
        assert min(np.abs(np.array(found) - expected).max(axis=1)) < 0.05
    pieces = P.split_by_labels(mesh, labels, palette)
    assert len(pieces) == 3
    assert all(p.mesh.is_watertight for p in pieces)
    assert sum(p.mesh.volume for p in pieces) == pytest.approx(mesh.volume, rel=1e-4)
    assert _max_overlap(pieces) < 1e-3


@pytest.mark.parametrize("kind, count", [("pivote", 2), ("espiga", 3)])
def test_plane_cut_connector_clearance(kind, count):
    cylinder = trimesh.creation.cylinder(radius=10, height=60, sections=96)
    pieces = P.plane_cut(cylinder, (0, 0, 1), 5.0, kind=kind, clearance=0.2)
    assert len(pieces) == count
    assert all(p.mesh.is_watertight and p.bodies == 1 for p in pieces)
    assert _max_overlap(pieces[:2]) < 1e-3
    if kind == "pivote":
        big, small = pieces[0].mesh, pieces[1].mesh
        peg = big.vertices[big.vertices[:, 2] > 5.5]
        gap = np.abs(trimesh.proximity.signed_distance(small, peg)).min()
        assert gap == pytest.approx(0.2, abs=0.02)


def test_pipeline_divides_scan_by_color(tmp_path: Path):
    # "Escaneo" como sale de RealityKit: metros, Y arriba, con colores.
    mesh = colored_figure()
    mesh.apply_scale(0.001)
    mesh.apply_transform(trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0]))
    scan = tmp_path / "scan.ply"
    mesh.export(scan)

    result = run_pipeline(PipelineOptions(
        input_path=scan, output_dir=tmp_path / "out", up_axis="y", skip_plane_removal=True,
        symmetry="off", target_triangles=60_000, parts_by="color", parts_colors=3,
    ), log=lambda *_: None)

    out = tmp_path / "out" / "partes"
    assert len(result["partes"]) == 3
    assert (out / "ensamblaje.3mf").exists() and (out / "partes.json").exists()
    colors = {p["color"] for p in result["partes"]}
    assert any(c and int(c[5:7], 16) > 150 and int(c[1:3], 16) < 80 for c in colors)  # el pelo azul
    assert all(p["cerrada"] for p in result["partes"]), result["partes"]
