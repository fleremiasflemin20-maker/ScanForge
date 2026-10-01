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
    parser.add_argument("--input", required=True, help="Archivo OBJ o USDZ de entrada.")
    parser.add_argument("--output", required=True, help="Carpeta de salida.")
    parser.add_argument("--basename", default="model", help="Nombre base de los archivos de salida (default: model).")

    dims = parser.add_mutually_exclusive_group(required=True)
    dims.add_argument("--height-mm", type=float, help="Altura real conocida del objeto en mm (eje Z tras orientar).")
    dims.add_argument("--width-mm", type=float, help="Ancho real conocido del objeto en mm (eje X).")
    dims.add_argument("--depth-mm", type=float, help="Profundidad real conocida del objeto en mm (eje Y).")
    dims.add_argument("--scale", type=float, help="Factor de escala relativo directo.")

    parser.add_argument("--target-triangles", type=int, default=200_000, help="Número máximo de triángulos tras decimar (default: 200000).")
    parser.add_argument("--infill", type=float, default=0.2, help="Relleno (0-1) para estimar el peso de filamento (default: 0.2).")
    parser.add_argument("--density", type=float, default=PLA_DENSITY_G_CM3, help=f"Densidad del filamento en g/cm3 (default: {PLA_DENSITY_G_CM3}, PLA).")
    parser.add_argument("--max-hole-size", type=int, default=500, help="Tamaño máximo de agujero (en aristas) a rellenar automáticamente (default: 500).")
    parser.add_argument("--skip-plane-removal", action="store_true", help="No intentar detectar/cortar un plano de mesa (usa esto si ya capturaste el objeto aislado, p.ej. con --object-masking).")

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
