from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .pipeline import PipelineOptions, run_pipeline
from .report import PLA_DENSITY_G_CM3


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mesh-prep",
        description="Convierte un OBJ/USDZ de fotogrametría en una malla lista para imprimir (3MF/STL).",
    )
    parser.add_argument("--input", required=True, help="Archivo OBJ, STL, PLY o USDZ de entrada.")
    parser.add_argument("--output", required=True, help="Carpeta de salida.")
    parser.add_argument("--basename", default="model", help="Nombre base de los archivos de salida (default: model).")

    dims = parser.add_mutually_exclusive_group()
    dims.add_argument("--height-mm", type=float, help="Altura real conocida del objeto en mm (eje Z tras orientar).")
    dims.add_argument("--width-mm", type=float, help="Ancho real conocido del objeto en mm (eje X).")
    dims.add_argument("--depth-mm", type=float, help="Profundidad real conocida del objeto en mm (eje Y).")
    dims.add_argument("--longest-mm", type=float, help="Medida real del lado más largo (con calibre): calibra la escala. Lo más exacto para piezas mecánicas.")
    dims.add_argument("--scale", type=float, help="Factor de escala relativo directo. Sin ninguna de estas opciones se usa la escala real del escaneo (metros -> mm automático).")

    parser.add_argument("--target-triangles", type=int, default=200_000, help="Número máximo de triángulos tras decimar (default: 200000).")
    parser.add_argument("--infill", type=float, default=0.2, help="Relleno (0-1) para estimar el peso de filamento (default: 0.2).")
    parser.add_argument("--density", type=float, default=PLA_DENSITY_G_CM3, help=f"Densidad del filamento en g/cm3 (default: {PLA_DENSITY_G_CM3}, PLA).")
    parser.add_argument("--max-hole-size", type=int, default=500, help="Tamaño máximo de agujero (en aristas) a rellenar automáticamente (default: 500).")
    parser.add_argument("--skip-plane-removal", action="store_true", help="No intentar detectar/cortar un plano de mesa (usa esto si ya capturaste el objeto aislado, p.ej. con --object-masking).")

    parser.add_argument("--up-axis", choices=["z", "y"], default="z", help="Eje vertical de la entrada: y para OBJ/USDZ de mac-reconstruct, z para STL/OBJ/PLY de la app (default: z).")
    parser.add_argument("--no-complete", action="store_true", help="No completar las zonas sin escanear (solo rellena agujeros pequeños).")
    parser.add_argument("--symmetry", choices=["auto", "off"], default="auto", help="Reconstruir lo que falta reflejando la pieza si es simétrica (default: auto).")
    parser.add_argument("--denoise", action="store_true", help="Suavizar el ruido del escaneo conservando aristas vivas.")
    parser.add_argument("--transform", help="charuco-transform.json (python -m mesh_prep.charuco solve): escala y orientación exactas del tablero.")
    parser.add_argument("--parts", choices=["shape", "color"], help="Dividir en partes: shape (anatomía, cortes planos con encaje) o color (zonas de color para AMS).")
    parser.add_argument("--parts-colors", type=int, default=4, help="Colores/filamentos para --parts color (default: 4).")
    parser.add_argument("--parts-max", type=int, default=10, help="Máximo de partes para --parts shape (default: 10).")
    parser.add_argument("--connector", choices=["pivote", "espiga", "ninguno"], default="pivote", help="Encaje entre partes (default: pivote hexagonal).")
    parser.add_argument("--clearance", type=float, default=0.2, help="Holgura del encaje en mm (default: 0.2).")
    parser.add_argument("--mechanical", action="store_true", help="Pieza técnica: aplana caras planas a su plano exacto para ranuras y encajes nítidos (activa --denoise).")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    options = PipelineOptions(
        input_path=Path(args.input),
        output_dir=Path(args.output),
        basename=args.basename,
        height_mm=args.height_mm,
        width_mm=args.width_mm,
        depth_mm=args.depth_mm,
        scale=args.scale,
        target_triangles=args.target_triangles,
        infill_fraction=args.infill,
        density_g_cm3=args.density,
        skip_plane_removal=args.skip_plane_removal,
        max_hole_size=args.max_hole_size,
        up_axis=args.up_axis,
        complete=not args.no_complete,
        symmetry=args.symmetry,
        denoise=args.denoise,
        mechanical=args.mechanical,
        longest_mm=args.longest_mm,
        transform_path=Path(args.transform) if args.transform else None,
        parts_by=args.parts,
        parts_colors=args.parts_colors,
        parts_max=args.parts_max,
        connector=args.connector,
        clearance=args.clearance,
    )

    try:
        result = run_pipeline(options)
    except Exception as e:
        print(f"\n✗ Error: {e}", file=sys.stderr)
        return 1

    print("\nResumen:")
    print(f"  Dimensiones (mm): {result['dimensions_mm']}")
    print(f"  Triángulos: {result['triangle_count']}")
    print(f"  Watertight: {result['is_watertight']}")
    print(f"  Peso estimado: {result['estimated_weight_g']['weight_g']} g")
    return 0


if __name__ == "__main__":
    sys.exit(main())
