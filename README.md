# ScanForge

Escanea un objeto real con el iPhone, reconstrúyelo en 3D en el Mac y deja la malla
lista para imprimir sin retoques manuales.

```
iPhone (ios-capture) --fotos--> Mac (mac-reconstruct) --OBJ--> Mac (mesh-prep) --3MF/STL--> Creality Print
```

## Componentes

| Carpeta | Qué es | Dónde corre | Estado |
|---|---|---|---|
| [`ios-capture/`](ios-capture/) | App SwiftUI: captura guiada con LiDAR u modo manual AVFoundation | iPhone (17 Pro+) | Escrito, **sin compilar/probar** (no hay Xcode en este entorno) |
| [`mac-reconstruct/`](mac-reconstruct/) | CLI Swift: fotos → USDZ/OBJ con PhotogrammetrySession | Mac (Apple Silicon, macOS 14+) | Escrito, **sin compilar/probar** |
| [`mesh-prep/`](mesh-prep/) | Pipeline Python: OBJ → malla imprimible (3MF/STL) | Mac (o cualquier máquina) | **Probado**: pipeline completo validado con mallas sintéticas (`pytest`, 4/4 ok) |
| [`scripts/`](scripts/) | Orquestador end-to-end + receptor de subidas (Fase 3) | Mac | `receive_uploads.py` probado con un cliente simulado; `scanforge.sh` no probado (depende de los dos binarios de arriba) |

## Primer uso en tu Mac Mini

```bash
# 1. mac-reconstruct
cd mac-reconstruct
swift build -c release
cp .build/release/mac-reconstruct /usr/local/bin/   # o deja la ruta en MAC_RECONSTRUCT_BIN

# 2. mesh-prep
cd ../mesh-prep
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
pytest   # confirma que el pipeline funciona en tu máquina

# 3. ios-capture
cd ../ios-capture
brew install xcodegen
xcodegen generate
open ScanForge.xcodeproj
# Signing & Capabilities -> tu Team -> Run en el iPhone

# 4. End-to-end
cd ../scripts
chmod +x scanforge.sh
./scanforge.sh --input <carpeta-de-fotos> --name mi-objeto --height-mm 150
```

## Por qué está estructurado así

- **mac-reconstruct separado de mesh-prep**: `PhotogrammetrySession` solo existe en
  RealityKit/macOS — no hay forma de llamarlo desde Python. Por eso la reconstrucción
  es un CLI en Swift y la limpieza/preparación de malla (donde pymeshlab/trimesh son
  mejores herramientas) es un pipeline en Python separado, unidos por un archivo OBJ.
- **Detección de mesa en mesh-prep, no en captura**: en vez de pedirte que captures ya
  "aislado", el pipeline busca la región plana más grande en un extremo de la nube de
  puntos (la mesa) y la corta — así puedes escanear sobre cualquier superficie con
  textura. Si prefieres aislar el objeto al capturar (`--object-masking`), usa
  `--skip-plane-removal` en mesh-prep para no buscar una mesa que no existe.
- **LiDAR vs manual se decide en runtime** (`ObjectCaptureSession.isSupported`), no al
  compilar: la misma app sirve para tu 17 Pro y para cualquier iPhone sin LiDAR.

## Qué falta probar de verdad

Este proyecto se construyó en un entorno Windows sin Xcode ni un Mac con Apple
Silicon a mano, así que **ni `ios-capture` ni `mac-reconstruct` se compilaron ni se
ejecutaron ni una vez** — están escritos siguiendo la forma real de las APIs de Apple
(Object Capture de WWDC23, PhotogrammetrySession del sample `HelloPhotogrammetry`),
pero hay que validarlos en tu Mac/iPhone antes de confiar en ellos para una pieza real.
`mesh-prep` sí se instaló y probó en este entorno (pytest, 4 casos) con mallas
sintéticas que simulan un objeto sobre una mesa, con fragmentos sueltos y agujeros de
ruido — el algoritmo de detección/corte de mesa y generación de base plana funciona de
verdad, no es solo código sin ejecutar.
