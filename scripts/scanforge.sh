#!/usr/bin/env bash
# Orquestador de punta a punta: carpeta de capturas -> mac-reconstruct -> mesh-prep.
# Pensado para correr en el Mac Mini (requiere macOS 14+, Apple Silicon).
set -euo pipefail

usage() {
    cat <<'EOF'
Uso:
  scanforge.sh --input <carpeta-de-fotos> --name <nombre-objeto> [opciones]

Obligatorios:
  --input <dir>         Carpeta con las fotos capturadas (de ios-capture o cualquier otra fuente)
  --name <nombre>        Nombre del objeto (usado para nombrar las carpetas de salida)

Opcionales:
  --height-mm <mm>       Altura real del objeto en mm. Sin ninguna medida se usa la escala
                         real que da el LiDAR (fotos de Objeto Pro) — recomendado.
  --width-mm <mm>        Alternativa a --height-mm
  --depth-mm <mm>        Alternativa a --height-mm
  --scale <factor>       Alternativa directa a las anteriores
  --detail <nivel>       preview|reduced|medium|full|raw (default: full)
  --feature-sensitivity  normal|high (default: normal)
  --no-object-masking    Desactiva el enmascarado (por defecto se aísla la pieza del fondo)
  --no-complete          No completar las zonas sin escanear
  --symmetry <auto|off>  Reconstruir lo que falta por simetría (default: auto)
  --denoise              Suavizar ruido conservando aristas
  --mechanical           Pieza técnica: caras planas exactas, aristas vivas (ranuras/encajes)
  --longest-mm <mm>      Lado más largo medido con calibre: calibra la escala
  --parts <shape|color>  Dividir en partes: anatomía (cortes planos + encaje) o colores (AMS)
  --parts-colors <n>     Colores para --parts color (default: 4)
  --connector <tipo>     pivote | espiga | ninguno (default: pivote)
  --clearance <mm>       Holgura del encaje (default: 0.2)
  --open <app>           Abrir el resultado en un slicer, p.ej. "Bambu Studio" u "OrcaSlicer"
  --target-triangles <n> Triángulos objetivo tras decimar (default: 200000)
  --infill <0-1>         Relleno usado para estimar peso de filamento (default: 0.2)
  --workdir <dir>        Carpeta base para reconstrucciones/impresión (default: ~/ScanForge)
  --skip-plane-removal   Pasa a mesh-prep: no cortar plano de mesa (objeto ya aislado)

Rutas de los binarios (si no están en PATH):
  MAC_RECONSTRUCT_BIN=/ruta/a/mac-reconstruct
  MESH_PREP_BIN=/ruta/a/mesh-prep (por defecto scripts/mesh-prep.sh, que usa mesh-prep/.venv)
EOF
}

WORKDIR="${WORKDIR:-$HOME/ScanForge}"
DETAIL="full"
FEATURE_SENSITIVITY="normal"
OBJECT_MASKING=true
COMPLETE=true
SYMMETRY=auto
DENOISE=false
MECHANICAL=false
LONGEST_MM=""
PARTS=""
PARTS_COLORS=4
CONNECTOR=pivote
CLEARANCE=0.2
OPEN_APP=""
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
        --no-object-masking) OBJECT_MASKING=false; shift ;;
        --no-complete) COMPLETE=false; shift ;;
        --symmetry) SYMMETRY="$2"; shift 2 ;;
        --denoise) DENOISE=true; shift ;;
        --mechanical) MECHANICAL=true; shift ;;
        --longest-mm) LONGEST_MM="$2"; shift 2 ;;
        --parts) PARTS="$2"; shift 2 ;;
        --parts-colors) PARTS_COLORS="$2"; shift 2 ;;
        --connector) CONNECTOR="$2"; shift 2 ;;
        --clearance) CLEARANCE="$2"; shift 2 ;;
        --open) OPEN_APP="$2"; shift 2 ;;
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_RECONSTRUCT="$SCRIPT_DIR/../mac-reconstruct/.build/release/mac-reconstruct"
if [[ -z "${MAC_RECONSTRUCT_BIN:-}" && -x "$LOCAL_RECONSTRUCT" ]]; then MAC_RECONSTRUCT_BIN="$LOCAL_RECONSTRUCT"; fi
MAC_RECONSTRUCT_BIN="${MAC_RECONSTRUCT_BIN:-mac-reconstruct}"
MESH_PREP_BIN="${MESH_PREP_BIN:-$SCRIPT_DIR/mesh-prep.sh}"

RECON_DIR="$WORKDIR/reconstructions/$NAME"
PRINT_DIR="$WORKDIR/printable/$NAME"
mkdir -p "$RECON_DIR" "$PRINT_DIR"

PY="$SCRIPT_DIR/../mesh-prep/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
run_py() { PYTHONPATH="$SCRIPT_DIR/../mesh-prep${PYTHONPATH:+:$PYTHONPATH}" "$PY" -m "$@"; }

echo "=== 1/4: fotos nítidas ==="
STAGED="$RECON_DIR/fotos-nitidas"
run_py mesh_prep.sharpness --input "$INPUT" --output "$STAGED"

echo
echo "=== 2/4: mac-reconstruct (máscaras de la pieza + poses) ==="
RECONSTRUCT_ARGS=(--input "$STAGED" --output "$RECON_DIR" --detail "$DETAIL" --feature-sensitivity "$FEATURE_SENSITIVITY" --poses "$RECON_DIR/poses.json")
if [[ "$OBJECT_MASKING" == true ]]; then
    RECONSTRUCT_ARGS+=(--masks)
fi
"$MAC_RECONSTRUCT_BIN" "${RECONSTRUCT_ARGS[@]}"

OBJ_PATH="$(ls "$RECON_DIR"/model-obj/*.obj 2>/dev/null | head -1)"
if [[ -z "$OBJ_PATH" ]]; then
    echo "mac-reconstruct no generó el OBJ en $RECON_DIR/model-obj" >&2
    exit 1
fi

echo
echo "=== 3/4: escala con tablero ChArUco ==="
TRANSFORM=""
if [[ -f "$RECON_DIR/poses.json" ]] && run_py mesh_prep.charuco solve --images "$STAGED" --poses "$RECON_DIR/poses.json" --output "$RECON_DIR/charuco-transform.json"; then
    TRANSFORM="$RECON_DIR/charuco-transform.json"
else
    echo "Sin tablero ChArUco visible: se usa la escala del LiDAR (o --longest-mm si la indicaste)."
fi

echo
echo "=== 4/4: mesh-prep ==="
# RealityKit exporta en metros con Y arriba: mesh-prep pasa a mm (escala LiDAR) y Z arriba.
MESH_PREP_ARGS=(--input "$OBJ_PATH" --output "$PRINT_DIR" --target-triangles "$TARGET_TRIANGLES" --infill "$INFILL" --up-axis y --symmetry "$SYMMETRY")
if [[ -n "$TRANSFORM" && -z "$LONGEST_MM$HEIGHT_MM$WIDTH_MM$DEPTH_MM$SCALE" ]]; then MESH_PREP_ARGS+=(--transform "$TRANSFORM"); fi
if [[ "$COMPLETE" == false ]]; then MESH_PREP_ARGS+=(--no-complete); fi
if [[ "$DENOISE" == true ]]; then MESH_PREP_ARGS+=(--denoise); fi
if [[ "$MECHANICAL" == true ]]; then MESH_PREP_ARGS+=(--mechanical); fi
if [[ -n "$LONGEST_MM" ]]; then MESH_PREP_ARGS+=(--longest-mm "$LONGEST_MM"); fi
if [[ -n "$PARTS" ]]; then MESH_PREP_ARGS+=(--parts "$PARTS" --parts-colors "$PARTS_COLORS" --connector "$CONNECTOR" --clearance "$CLEARANCE"); fi
if [[ -n "$HEIGHT_MM" ]]; then MESH_PREP_ARGS+=(--height-mm "$HEIGHT_MM"); fi
if [[ -n "$WIDTH_MM" ]]; then MESH_PREP_ARGS+=(--width-mm "$WIDTH_MM"); fi
if [[ -n "$DEPTH_MM" ]]; then MESH_PREP_ARGS+=(--depth-mm "$DEPTH_MM"); fi
if [[ -n "$SCALE" ]]; then MESH_PREP_ARGS+=(--scale "$SCALE"); fi
if [[ "$SKIP_PLANE_REMOVAL" == true ]]; then MESH_PREP_ARGS+=(--skip-plane-removal); fi
# Con tablero el plano Z=0 es la mesa: se corta y se genera la base plana.
if [[ "$OBJECT_MASKING" == true && -z "$TRANSFORM" ]]; then MESH_PREP_ARGS+=(--skip-plane-removal); fi

"$MESH_PREP_BIN" "${MESH_PREP_ARGS[@]}"

echo
echo "=== Listo ==="
echo "3MF/STL en: $PRINT_DIR"
echo "Reporte:    $PRINT_DIR/model.report.json"
echo "Abre el 3MF en Bambu Studio, Creality Print u OrcaSlicer para laminar."
if [[ -n "$OPEN_APP" ]]; then
    TO_OPEN="$PRINT_DIR/model.3mf"
    [[ -f "$PRINT_DIR/partes/ensamblaje.3mf" ]] && TO_OPEN="$PRINT_DIR/partes/ensamblaje.3mf"
    open -a "$OPEN_APP" "$TO_OPEN" || echo "No se pudo abrir $OPEN_APP" >&2
fi
