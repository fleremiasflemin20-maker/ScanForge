"""Priorización de fotos nítidas antes de reconstruir (como la "sharp image
prioritisation" de Artec Studio 20): una foto movida o desenfocada empeora la malla
más de lo que aporta. Se mide la nitidez (varianza del laplaciano) y se compara con
la mediana de su anillo, porque la nitidez absoluta depende de la pieza y la luz.

    python -m mesh_prep.sharpness --input fotos/ --output fotos-nitidas/

Crea `--output` con enlaces a las fotos aceptadas y `nitidez.json` con el ranking.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np

IMAGE_EXTENSIONS = {".heic", ".heif", ".jpg", ".jpeg", ".png"}


def laplacian_variance(path: Path, max_side: int = 800) -> float:
    from PIL import Image, ImageOps
    from pillow_heif import register_heif_opener

    register_heif_opener()
    with Image.open(path) as img:
        img = ImageOps.exif_transpose(img).convert("L")
        img.thumbnail((max_side, max_side))
        g = np.asarray(img, dtype=np.float64)
    lap = g[1:-1, :-2] + g[1:-1, 2:] + g[:-2, 1:-1] + g[2:, 1:-1] - 4 * g[1:-1, 1:-1]
    return float(lap.var())


def ring_of(path: Path, index: int, ring_size: int) -> str:
    """Anillo de la foto: el prefijo de la app (low/mid/high/flip-…) o, para nombres
    numéricos de Object Capture, bloques consecutivos de `ring_size` fotos."""
    match = re.match(r"([a-zA-Z]+)-\d+", path.stem)
    return match.group(1) if match else f"bloque{index // ring_size}"


def rank(folder: Path, threshold: float = 0.45, ring_size: int = 36) -> list[dict]:
    images = sorted(p for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS
                    and not p.stem.endswith("_mask"))
    entries = [{"archivo": p.name, "anillo": ring_of(p, i, ring_size), "nitidez": laplacian_variance(p)}
               for i, p in enumerate(images)]
    for ring in {e["anillo"] for e in entries}:
        members = [e for e in entries if e["anillo"] == ring]
        median = float(np.median([e["nitidez"] for e in members]))
        for e in members:
            e["relativa"] = round(e["nitidez"] / median, 3) if median > 0 else 1.0
            e["aceptada"] = len(members) < 4 or e["relativa"] >= threshold
    return entries


def stage(folder: Path, output: Path, entries: list[dict]) -> int:
    """Enlaza las fotos aceptadas (y sus máscaras `_mask`, si existen) en `output`."""
    output.mkdir(parents=True, exist_ok=True)
    for old in output.iterdir():
        if old.is_symlink():
            old.unlink()
    kept = 0
    for e in entries:
        if not e["aceptada"]:
            continue
        src = folder / e["archivo"]
        (output / src.name).symlink_to(src.resolve())
        for mask in folder.glob(f"{src.stem}_mask.*"):
            (output / mask.name).symlink_to(mask.resolve())
        kept += 1
    (output / "nitidez.json").write_text(json.dumps(entries, indent=2, ensure_ascii=False), encoding="utf-8")
    return kept


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="scanforge-sharpness", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, help="Carpeta con las fotos.")
    parser.add_argument("--output", required=True, help="Carpeta de salida con las fotos aceptadas (enlaces).")
    parser.add_argument("--threshold", type=float, default=0.45,
                        help="Nitidez mínima relativa a la mediana del anillo (default: 0.45).")
    args = parser.parse_args(argv)

    folder = Path(args.input)
    entries = rank(folder, args.threshold)
    if not entries:
        print("✗ No hay fotos en la carpeta.", file=sys.stderr)
        return 1
    kept = stage(folder, Path(args.output), entries)
    rejected = [e for e in entries if not e["aceptada"]]
    print(f"Nitidez: {kept}/{len(entries)} fotos aceptadas")
    for e in rejected:
        print(f"  descartada {e['archivo']} ({e['anillo']}, {e['relativa']:.0%} de la mediana): repite ese ángulo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
