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

## Mac (opcional: máximo detalle con fotos)

```bash
cd mac-reconstruct && swift build -c release
./scripts/scanforge.sh --input <carpeta-de-fotos> --name mi-objeto --height-mm 150
```

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
