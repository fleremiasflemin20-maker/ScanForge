"""Orquesta el pipeline completo: carga -> orientación -> limpieza -> [suavizado] ->
corte de mesa -> base plana -> completado (simetría + Poisson) -> escala -> centrado ->
decimado -> export -> reporte."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
import trimesh

from . import cleanup, completion, decimate, io, mechanical, orientation, plane_removal, report, scaling

Logger = Callable[[str], None]


@dataclass
class PipelineOptions:
    input_path: Path
    output_dir: Path
    basename: str = "model"
    height_mm: float | None = None
    width_mm: float | None = None
    depth_mm: float | None = None
    scale: float | None = None
    target_triangles: int = 200_000
    infill_fraction: float = 0.2
    density_g_cm3: float = report.PLA_DENSITY_G_CM3
    skip_plane_removal: bool = False
    max_hole_size: int = 500
    # "y" para OBJ/USDZ de RealityKit (Y arriba); "z" para lo que exporta la app (Z arriba).
    up_axis: str = "z"
    # Completa las zonas sin escanear y cierra la malla (Poisson con transferencia de detalle).
    complete: bool = True
    # "auto": usa la simetría solo si la pieza es claramente simétrica; "off": nunca.
    symmetry: str = "auto"
    denoise: bool = False
    # Pieza técnica: aplana caras planas a su plano exacto (ranuras, encajes, bridas).
    mechanical: bool = False
    # Medida real más larga de la pieza (calibre), corrige la escala del escaneo.
    longest_mm: float | None = None
    # charuco-transform.json: lleva la reconstrucción a mm reales con el tablero en Z=0.
    transform_path: Path | None = None


def run_pipeline(options: PipelineOptions, log: Logger = print) -> dict:
    log(f"[1/9] Cargando {options.input_path}")
    mesh = io.load_mesh(options.input_path)
    log(f"      {len(mesh.vertices)} vértices, {len(mesh.faces)} triángulos")
    if options.transform_path is not None:
        import json

        t = json.loads(Path(options.transform_path).read_text())
        mesh.apply_transform(np.array(t["matriz"]))
        options.scale = 1.0
        log(f"      Escala y orientación del tablero ChArUco: x{t['escala']:.5g}, "
            f"residuo {t['residuo_medio_mm']} mm con {t['fotos']} fotos")
    elif options.up_axis == "y":
        mesh = orientation.y_up_to_z_up(mesh)
        log("      Orientación: Y arriba (RealityKit) -> Z arriba (slicer)")

    log("[2/9] Eliminando fragmentos sueltos (quedándonos con la pieza principal)")
    mesh = cleanup.keep_largest_component(mesh)
    log(f"      {len(mesh.faces)} triángulos tras el filtrado")
    if options.denoise or options.mechanical:
        mesh = completion.denoise(mesh)
        log("      Ruido suavizado conservando aristas")

    plane = None
    if not options.skip_plane_removal:
        log("[3/9] Detectando el plano de mesa/soporte")
        plane = plane_removal.detect_support_plane(mesh)
        if plane is None:
            log("      No se detectó un plano de mesa claro; se omite el corte (usa --skip-plane-removal para silenciar este aviso).")
        else:
            log(f"      Plano detectado (cubre {plane.face_area_fraction:.1%} del área total)")
            mesh = orientation.orient_to_canonical_frame(mesh, plane)
            canonical_plane = plane_removal.SupportPlane(
                normal=np.array([0.0, 0.0, 1.0]), offset=0.0, face_area_fraction=plane.face_area_fraction
            )
            mesh = plane_removal.cut_support_plane(mesh, canonical_plane)
            mesh = cleanup.keep_largest_component(mesh)
            log(f"      {len(mesh.faces)} triángulos tras cortar la mesa")
    else:
        log("[3/9] Corte de plano de mesa omitido (--skip-plane-removal)")

    if plane is not None:
        log("[4/9] Generando base plana en el corte")
        mesh = orientation.generate_flat_base(mesh)
        log(f"      {len(mesh.faces)} triángulos tras generar la base")
    else:
        log("[4/9] Sin plano cortado, no se genera base plana explícita")

    # Con completado solo se cierran agujeritos aquí: los grandes los necesita la
    # detección de simetría y luego los rellena Poisson.
    mesh = cleanup.fill_holes_and_repair(mesh, max_hole_size=30 if options.complete else options.max_hole_size)
    if options.complete:
        log("[5/9] Completando la pieza (zonas sin escanear) y cerrando la malla")
        extra_points = extra_normals = None
        if options.symmetry != "off":
            mirror = completion.detect_mirror_symmetry(mesh)
            if mirror is None:
                log("      Sin simetría clara: se completa siguiendo la curvatura (Poisson)")
            else:
                extra_points, extra_normals = completion.symmetry_fill_points(mesh, mirror)
                log(f"      Simetría detectada (error x{mirror.score:.2f} sobre el ruido de muestreo): "
                    f"{len(extra_points)} puntos reflejados rellenan la zona que falta")
        mesh = completion.complete_watertight(mesh, extra_points, extra_normals)
    else:
        log("[5/9] Rellenando agujeros restantes y reparando no-manifold")
    if options.mechanical:
        total = 0
        for _ in range(2):  # 2 pasadas: los vértices de arista convergen a la intersección
            mesh, applied = mechanical.flatten_planar_faces(mesh)
            total = max(total, applied)
        log(f"      Pieza mecánica: {total} caras planas ajustadas a su plano exacto (aristas vivas)")
    log(f"      watertight={mesh.is_watertight}, winding_consistente={mesh.is_winding_consistent}")

    log("[6/9] Escalando a milímetros")
    if options.transform_path is not None:
        log("      Ya en milímetros reales (tablero ChArUco)")
    elif options.longest_mm is not None:
        options.scale = options.longest_mm / scaling.robust_longest_extent(mesh)
        log(f"      Calibrado con la medida real: lado mayor = {options.longest_mm:g} mm (x{options.scale:.4g})")
    elif all(v is None for v in (options.height_mm, options.width_mm, options.depth_mm, options.scale)):
        options.scale = scaling.auto_scale_factor(mesh)
        log(f"      Escala real del escaneo (LiDAR): x{options.scale:g}")
    mesh = scaling.scale_mesh(
        mesh,
        height_mm=options.height_mm,
        width_mm=options.width_mm,
        depth_mm=options.depth_mm,
        scale=options.scale,
    )
    log(f"      dimensiones: {tuple(round(v, 1) for v in mesh.extents)} mm")

    if plane is not None:
        log("[7/9] Centrando y apoyando sobre la cama (Z=0)")
        mesh = orientation.center_and_drop_to_bed(mesh)
    else:
        log("[7/9] Centrando en X/Y (sin plano de referencia para apoyar en Z=0 con certeza)")
        mesh = orientation.center_and_drop_to_bed(mesh)

    log(f"[8/9] Decimando a un máximo de {options.target_triangles} triángulos")
    mesh = decimate.decimate_to_target(mesh, options.target_triangles)
    log(f"      {len(mesh.faces)} triángulos finales")

    log("[9/9] Exportando 3MF/STL y generando reporte")
    paths = io.export_mesh(mesh, options.output_dir, options.basename)
    result = report.build_report(mesh, infill_fraction=options.infill_fraction, density_g_cm3=options.density_g_cm3)
    report_path = options.output_dir / f"{options.basename}.report.json"
    report.write_report(result, report_path)

    log(f"      3MF: {paths['3mf']}")
    log(f"      STL: {paths['stl']}")
    log(f"      Reporte: {report_path}")

    if not result["is_watertight"]:
        log("⚠️  La malla final NO es watertight. Revisa --max-hole-size o la cobertura de fotos en la captura; "
            "muchos slicers (incluido Creality Print) pueden repararla automáticamente, pero no está garantizado.")

    return result
