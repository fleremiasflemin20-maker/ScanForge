# ScanForge Pro

Escáner 3D profesional con el **iPhone 17 Pro**: replica las tecnologías de los escáneres
de Creality, Revopoint, Artec y el nuevo Bambu Lab S1 usando el LiDAR, la cámara
TrueDepth (luz estructurada infrarroja) y la cámara de 48 MP. El resultado es un STL a
escala real, listo para Bambu Studio, Creality Print u OrcaSlicer.

**📲 Instalar en el iPhone sin App Store → [INSTALAR.md](INSTALAR.md)**
· **🔬 Investigación de tecnologías → [docs/TECNOLOGIA.md](docs/TECNOLOGIA.md)**

```
iPhone (ScanForge Pro) ──► STL/OBJ en mm ──► slicer (Bambu Studio / Creality Print)
        │
        ├─ PLY (nube) ──► mesh-prep (Poisson + reparación) ──► 3MF/STL
        └─ fotos ──► Mac: mac-reconstruct ──► mesh-prep ──► 3MF/STL
```

## Modos de escaneo

| Modo | Sensor | Equivale a… | Ideal para | Sale |
|---|---|---|---|---|
| **Objeto Pro** | Cámara 48 MP + LiDAR (Object Capture) | Cámara de textura + fotogrametría, procesado sin PC como el MIRACO | Objetos con textura de 5 cm a 2 m, máximo detalle y color | USDZ + STL + OBJ, **reconstruido en el iPhone** |
| **LiDAR Fusión** | LiDAR + seguimiento visual-inercial | Seguimiento híbrido de los escáneres de mano | Muebles, piezas grandes, personas, espacios | Nube PLY con color + malla STL/OBJ |
| **Micro TrueDepth** | Proyector de puntos IR + cámara IR | Luz estructurada NIR (Raptor en modo NIR, Revopoint) con seguimiento ICP | Piezas de 3 a 20 cm en una plataforma giratoria | Nube PLY (0,5–2 mm) → mesh-prep |
| **Fotos 48 MP** | Cámara principal | Captura offline de alta resolución | Reconstruir en el Mac con detalle máximo | Fotos HEIC → mac-reconstruct |

Funciones comunes:
- Vista 3D en vivo de la nube mientras escaneas.
- Indicadores de seguimiento con aviso háptico si se pierde.
- Exportación en **milímetros con Z hacia arriba**, para que el modelo entre a escala real y de pie en el slicer.
- Archivos accesibles en **Archivos → En mi iPhone → ScanForge** y para compartir por AirDrop.
- Subida opcional al Mac por la red local.

## Componentes

| Carpeta | Qué es | Dónde corre | Estado |
|---|---|---|---|
| [`ios-capture/`](ios-capture/) | App SwiftUI ScanForge Pro (4 modos) | iPhone (iOS 17+, todos los modos en 12 Pro y posteriores, incluido el 17 Pro) | **Compila** en GitHub Actions (Xcode 26.3). Pendiente de probar en un iPhone real |
| [`mac-reconstruct/`](mac-reconstruct/) | CLI Swift: fotos → USDZ/OBJ con PhotogrammetrySession | Mac (Apple Silicon) | Escrito, sin compilar |
| [`mesh-prep/`](mesh-prep/) | Pipeline Python: OBJ/STL/USDZ/**PLY** → malla imprimible 3MF/STL | Mac, Windows o Linux | **Probado**: `pytest` 5/5, incluida la nube PLY → Poisson |
| [`scripts/`](scripts/) | Orquestador end-to-end y receptor de subidas | Mac | Receptor probado con un cliente simulado |
| [`.github/workflows/`](.github/workflows/ios-build.yml) | Compila el `.ipa` sin firmar y lo publica en Releases | GitHub Actions (macOS) | Funcionando |

## Flujo rápido

1. Instala la app ([INSTALAR.md](INSTALAR.md)).
2. Escanea con **Objeto Pro** y pulsa **Reconstruir modelo 3D**. El STL aparece en la app.
3. Compártelo por AirDrop o Archivos y ábrelo en el slicer.

Para las nubes PLY de **LiDAR Fusión** y **Micro TrueDepth**:

```bash
cd mesh-prep
python -m venv .venv && .venv/Scripts/activate   # en Mac/Linux: source .venv/bin/activate
pip install -e .
mesh-prep --input objeto-truedepth.ply --output listo --scale 1 --skip-plane-removal
```

`--scale 1` se debe a que ScanForge Pro ya exporta en milímetros reales. Quita
`--skip-plane-removal` si escaneaste el objeto sobre una mesa y quieres cortarla.

## Mac: máxima calidad y completado automático

El iPhone solo puede reconstruir con detalle *reducido*; el Mac llega a **Full/Raw**.
Instalación (una vez):

```bash
cd mac-reconstruct && swift build -c release && cd ..
cd mesh-prep && uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e . && cd ..
```

Deja el receptor escuchando; cada escaneo que subas desde la app (botón **Máxima
calidad: procesar en el Mac**) se reconstruye, se completa y se abre en el slicer:

```bash
python3 scripts/receive_uploads.py --auto-process --open "Bambu Studio"
```

O a mano con una carpeta de fotos:

```bash
./scripts/scanforge.sh --input <carpeta-de-fotos> --name mi-objeto --open "OrcaSlicer"
```

Qué hace mesh-prep con la malla:

| Paso | Qué hace |
|---|---|
| Escala real | Las fotos de Objeto Pro llevan profundidad LiDAR: el modelo sale en metros reales y se pasa a mm sin medir nada (o fuerza una medida con `--height-mm`). |
| Orientación | Y arriba (RealityKit) → Z arriba (slicer) con `--up-axis y`. |
| Completado | Poisson *screened* cierra los huecos siguiendo la curvatura; donde sí hubo datos, la superficie vuelve a la medida original (no se pierde detalle). |
| Simetría | Si la pieza es claramente simétrica, la parte buena se refleja para reconstruir la que falta, solo dentro de los agujeros (`--symmetry off` para desactivarlo). |
| Suavizado | `--denoise`: quita el granulado conservando aristas vivas. |
| Pieza mecánica | `--mechanical`: detecta las caras planas (paredes de ranuras, asientos, bridas), las ajusta a su plano exacto y recorta los picos de las aristas. Lo curvo (agujeros, redondeos) no se toca. En la app: interruptor «Pieza mecánica». |
| Calibración | `--longest-mm 60`: lado más largo medido con calibre; corrige la escala ignorando picos sueltos. En la app: campo «Lado más largo». |

Precisión medida (pieza ranurada de 60×30×20 mm con ruido de escaneo de ±0,15 mm,
`--mechanical --longest-mm 60`): caras a 59,8 × 29,9 × 19,98 mm, malla cerrada. Para
encajes de tolerancia fina usa el STL como referencia y remodela en CAD (Fusion 360,
Onshape): es lo que se hace también con los escáneres profesionales.

> `scripts/mesh-prep.sh` ejecuta mesh-prep desde su `.venv` aunque macOS marque como
> ocultos los `.pth` de la instalación (pasa en Documentos sincronizado con iCloud).

## Protocolo pro con plato giratorio (Fase 1)

1. **Imprime el tablero** [`docs/tablero-charuco.pdf`](docs/tablero-charuco.pdf) al 100 %
   y comprueba con el calibre que un cuadro mide **16,00 mm**. Pégalo plano sobre el plato.
2. Pieza en el centro del tablero, iPhone en trípode, luz difusa (caja de luz). Piezas
   brillantes: spray de escaneo (AESUB) o polarización cruzada.
3. App → **Fotos 48 MP** → toca la pieza (enfoque fijo) → **Auto 2 s**. La app guía
   **4 vueltas de 36 fotos** (una cada 10°): baja, media, alta y la pieza volteada.
4. **Máxima calidad: procesar en el Mac**. El Mac hace, en orden:
   - `mesh_prep.sharpness`: descarta las fotos movidas de cada vuelta.
   - `mac-reconstruct --masks --poses`: máscara de la pieza con Vision (el fondo
     estático ya no confunde) y poses de cámara.
   - `mesh_prep.charuco solve`: escala **exacta en las 3 direcciones** y Z arriba a
     partir del tablero (error de escala estimado en el informe).
   - `mesh-prep --transform`: completado, modo mecánico, base plana y 3MF/STL.

### Medir la precisión real (VDI/VDE 2634 casero)

Escanea artefactos de medida conocida y compara:

```bash
python -m mesh_prep.validate --mesh bola.stl --sphere 25.4              # bola de rodamiento mateada
python -m mesh_prep.validate --mesh barra.stl --sphere 25.4 --spacing 100  # dos bolas a distancia conocida
python -m mesh_prep.validate --mesh vidrio.stl --plane                  # vidrio float / bloque patrón
```

Da error de forma (PF), de tamaño (PS), de distancia (SD) y planitud (F) en mm: es la
forma de comprobar cada mejora con números en vez de a ojo.

## Por qué está estructurado así

- **Reconstrucción en el iPhone y también en el Mac**: el iPhone procesa Object Capture
  sin PC (como el MIRACO). El Mac sigue disponible para el nivel de detalle más alto y
  para iPhones sin LiDAR.
- **mesh-prep separado**: la limpieza, la reparación, Poisson, el corte de mesa y la base
  plana se hacen mejor con pymeshlab/trimesh, y así corre también en Windows.
- **Los modos se activan en tiempo de ejecución** según los sensores del dispositivo: la
  misma app funciona en el 17 Pro y en iPhones sin LiDAR.

## Qué está verificado y qué no

- ✅ La app iOS **compila** sin errores con Xcode 26.3 en GitHub Actions y genera el `.ipa`.
- ✅ `mesh-prep` pasa sus 5 tests, incluida la reconstrucción Poisson de una nube PLY.
- ⚠️ La app **no se ha ejecutado todavía en un iPhone físico**: no hay simulador con
  LiDAR ni TrueDepth. El seguimiento ICP de Micro TrueDepth y los umbrales (distancias,
  inliers) quizá necesiten ajustes tras las primeras pruebas reales.
- ⚠️ `mac-reconstruct` no se ha compilado.
