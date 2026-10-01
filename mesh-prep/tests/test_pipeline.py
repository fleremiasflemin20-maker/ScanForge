from __future__ import annotations

from pathlib import Path

import pytest

from mesh_prep.pipeline import PipelineOptions, run_pipeline

from ._synthetic import build_isolated_object, build_object_on_table


@pytest.fixture
def object_on_table_obj(tmp_path: Path) -> Path:
    mesh = build_object_on_table()
    path = tmp_path / "scan.obj"
    mesh.export(str(path))
    return path


@pytest.fixture
def isolated_object_obj(tmp_path: Path) -> Path:
    mesh = build_isolated_object()
    path = tmp_path / "isolated.obj"
    mesh.export(str(path))
    return path


def test_pipeline_detects_and_cuts_table(object_on_table_obj: Path, tmp_path: Path):
    options = PipelineOptions(
        input_path=object_on_table_obj,
        output_dir=tmp_path / "out",
        height_mm=120.0,
        target_triangles=2_000,
    )
    result = run_pipeline(options, log=lambda *_: None)

    assert result["is_watertight"] is True
    assert result["is_winding_consistent"] is True
    assert result["triangle_count"] <= 2_000
    assert result["dimensions_mm"]["z"] == pytest.approx(120.0, abs=0.5)
    assert (tmp_path / "out" / "model.3mf").exists()
    assert (tmp_path / "out" / "model.stl").exists()
    assert (tmp_path / "out" / "model.report.json").exists()
    assert result["estimated_weight_g"]["weight_g"] > 0


def test_pipeline_skip_plane_removal_on_isolated_object(isolated_object_obj: Path, tmp_path: Path):
    options = PipelineOptions(
        input_path=isolated_object_obj,
        output_dir=tmp_path / "out",
        height_mm=80.0,
        target_triangles=500,
        skip_plane_removal=True,
    )
    result = run_pipeline(options, log=lambda *_: None)

    assert result["is_watertight"] is True
    assert result["dimensions_mm"]["z"] == pytest.approx(80.0, abs=0.5)
    assert result["triangle_count"] <= 500


def test_pipeline_auto_detection_falls_back_gracefully_without_table(isolated_object_obj: Path, tmp_path: Path):
    """Sin --skip-plane-removal, un objeto sin mesa no debe hacer que falle el pipeline:
    la detección de plano debe simplemente no encontrar nada y continuar."""
    options = PipelineOptions(
        input_path=isolated_object_obj,
        output_dir=tmp_path / "out",
        height_mm=80.0,
        target_triangles=500,
    )
    result = run_pipeline(options, log=lambda *_: None)

    assert result["is_watertight"] is True


def test_scale_requires_exactly_one_dimension_option(object_on_table_obj: Path, tmp_path: Path):
    options = PipelineOptions(
        input_path=object_on_table_obj,
        output_dir=tmp_path / "out",
        height_mm=120.0,
        width_mm=50.0,  # dos dimensiones a la vez -> error
    )
    with pytest.raises(Exception):
        run_pipeline(options, log=lambda *_: None)
