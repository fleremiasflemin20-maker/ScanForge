#!/usr/bin/env bash
# Orquestador de punta a punta: carpeta de capturas -> mac-reconstruct -> mesh-prep.
# Pensado para correr en el Mac Mini (requiere macOS 14+, Apple Silicon).
set -euo pipefail

usage() {
    cat <<'EOF'
Uso:
  scanforge.sh --input <carpeta-de-fotos> --name <nombre-objeto> --height-mm <mm> [opciones]

Obligatorios:
  --input <dir>         Carpeta con las fotos capturadas (de ios-capture o cualquier otra fuente)
  --name <nombre>        Nombre del objeto (usado para nombrar las carpetas de salida)
  --height-mm <mm>       Altura real del objeto en milímetros (o usa --width-mm/--depth-mm/--scale)

Opcionales:
  --width-mm <mm>        Alternativa a --height-mm
  --depth-mm <mm>        Alternativa a --height-mm
  --scale <factor>       Alternativa directa a las anteriores
  --detail <nivel>       preview|reduced|medium|full|raw (default: full)
  --feature-sensitivity  normal|high (default: normal)
  --object-masking       Activa el enmascarado de objeto en mac-reconstruct
  --target-triangles <n> Triángulos objetivo tras decimar (default: 200000)
  --infill <0-1>         Relleno usado para estimar peso de filamento (default: 0.2)
  --workdir <dir>        Carpeta base para reconstrucciones/impresión (default: ~/ScanForge)
  --skip-plane-removal   Pasa a mesh-prep: no cortar plano de mesa (objeto ya aislado)

Rutas de los binarios (si no están en PATH):
  MAC_RECONSTRUCT_BIN=/ruta/a/mac-reconstruct
  MESH_PREP_BIN=/ruta/a/mesh-prep (o "python3 -m mesh_prep.cli" si no se instaló con pip install -e .)
EOF
}

WORKDIR="${WORKDIR:-$HOME/ScanForge}"
DETAIL="full"
FEATURE_SENSITIVITY="normal"
OBJECT_MASKING=false
TARGET_TRIANGLES=200000
INFILL=0.2
SKIP_PLANE_REMOVAL=false
HEIGHT_MM=""
WIDTH_MM=""
DEPTH_MM=""
SCALE=""
INPUT=""
NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --height-mm) HEIGHT_MM="$2"; shift 2 ;;
        --width-mm) WIDTH_MM="$2"; shift 2 ;;
        --depth-mm) DEPTH_MM="$2"; shift 2 ;;
        --scale) SCALE="$2"; shift 2 ;;
        --detail) DETAIL="$2"; shift 2 ;;
        --feature-sensitivity) FEATURE_SENSITIVITY="$2"; shift 2 ;;
        --object-masking) OBJECT_MASKING=true; shift ;;
        --target-triangles) TARGET_TRIANGLES="$2"; shift 2 ;;
        --infill) INFILL="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --skip-plane-removal) SKIP_PLANE_REMOVAL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$INPUT" || -z "$NAME" ]]; then
    echo "Faltan --input y/o --name." >&2
    usage
    exit 1
fi
if [[ -z "$HEIGHT_MM" && -z "$WIDTH_MM" && -z "$DEPTH_MM" && -z "$SCALE" ]]; then
    echo "Indica una dimensión real: --height-mm, --width-mm, --depth-mm o --scale." >&2
    exit 1
fi

MAC_RECONSTRUCT_BIN="${MAC_RECONSTRUCT_BIN:-mac-reconstruct}"
MESH_PREP_BIN="${MESH_PREP_BIN:-mesh-prep}"

RECON_DIR="$WORKDIR/reconstructions/$NAME"
PRINT_DIR="$WORKDIR/printable/$NAME"
mkdir -p "$RECON_DIR" "$PRINT_DIR"

echo "=== 1/2: mac-reconstruct ==="
RECONSTRUCT_ARGS=(--input "$INPUT" --output "$RECON_DIR" --detail "$DETAIL" --feature-sensitivity "$FEATURE_SENSITIVITY")
if [[ "$OBJECT_MASKING" == true ]]; then
    RECONSTRUCT_ARGS+=(--object-masking)
fi
"$MAC_RECONSTRUCT_BIN" "${RECONSTRUCT_ARGS[@]}"

OBJ_PATH="$RECON_DIR/model.obj"
if [[ ! -f "$OBJ_PATH" ]]; then
    echo "mac-reconstruct no generó $OBJ_PATH" >&2
    exit 1
fi

echo
echo "=== 2/2: mesh-prep ==="
MESH_PREP_ARGS=(--input "$OBJ_PATH" --output "$PRINT_DIR" --target-triangles "$TARGET_TRIANGLES" --infill "$INFILL")
if [[ -n "$HEIGHT_MM" ]]; then MESH_PREP_ARGS+=(--height-mm "$HEIGHT_MM"); fi
if [[ -n "$WIDTH_MM" ]]; then MESH_PREP_ARGS+=(--width-mm "$WIDTH_MM"); fi
if [[ -n "$DEPTH_MM" ]]; then MESH_PREP_ARGS+=(--depth-mm "$DEPTH_MM"); fi
if [[ -n "$SCALE" ]]; then MESH_PREP_ARGS+=(--scale "$SCALE"); fi
if [[ "$SKIP_PLANE_REMOVAL" == true ]]; then MESH_PREP_ARGS+=(--skip-plane-removal); fi
if [[ "$OBJECT_MASKING" == true ]]; then MESH_PREP_ARGS+=(--skip-plane-removal); fi

$MESH_PREP_BIN "${MESH_PREP_ARGS[@]}"

echo
echo "=== Listo ==="
echo "3MF/STL en: $PRINT_DIR"
echo "Reporte:    $PRINT_DIR/model.report.json"
echo "Abre el 3MF en Creality Print para laminar."
