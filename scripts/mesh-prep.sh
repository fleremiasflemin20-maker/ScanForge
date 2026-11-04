#!/usr/bin/env bash
# Ejecuta mesh-prep desde su .venv sin depender de los .pth de la instalación editable:
# en carpetas sincronizadas (Documentos en iCloud) macOS los marca como ocultos y Python
# los ignora ("No module named mesh_prep").
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../mesh-prep"
PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" exec "$PY" -m mesh_prep.cli "$@"
