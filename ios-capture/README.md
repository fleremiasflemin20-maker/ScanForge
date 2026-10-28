# ios-capture — ScanForge Pro

App SwiftUI (iOS 17+) con cuatro modos de escaneo. Ver la tabla de modos en el
[README principal](../README.md) y cómo instalarla sin App Store en [INSTALAR.md](../INSTALAR.md).

## Estructura

```
Sources/
  ScanForgeApp.swift, ContentView.swift   inicio: nombre, selector de modo, historial
  Models/CaptureSession.swift             ScanMode, sesión, carpetas
  Capture/
    CaptureCoordinator.swift              detecta sensores (LiDAR, TrueDepth, Object Capture)
    LiDARCaptureView.swift                Objeto Pro: ObjectCaptureSession guiado
    ManualCaptureController/View.swift    Fotos 48 MP (HEIC, calidad máxima)
    CaptureExporter.swift                 metadatos y listado de archivos
  Fusion/
    VoxelCloud.swift                      rejilla de vóxeles (fusión) + escritor PLY
    LiDARFusionScanner/View.swift         LiDAR + ARKit: nube en tiempo real, zona de escaneo
    TrueDepthScanner/ScanView.swift       luz estructurada IR + plataforma giratoria
    ICPTracker.swift                      ICP punto-a-plano + RANSAC de plano
    PointCloudPreview.swift               vista 3D en vivo (SceneKit)
  Processing/OnDeviceReconstructor.swift  PhotogrammetrySession en el iPhone
  Export/MeshExporter.swift               STL/OBJ en mm (Z arriba), malla LiDAR, USDZ→STL
  Views/ResultView.swift                  resultado: reconstruir, ver, compartir, subir
  Networking/MacUploader.swift            subida al Mac por Bonjour
```

## Compilar

- **Sin Mac:** cada push compila en GitHub Actions
  ([`ios-build.yml`](../.github/workflows/ios-build.yml)) y deja `ScanForge.ipa` como
  artefacto; un tag `v*` crea una Release.
- **Con Mac:** `brew install xcodegen && xcodegen generate && open ScanForge.xcodeproj`

## Carpeta de cada escaneo

`Documents/ScanForgeCaptures/<objeto>-<fecha>/` (visible en Archivos → En mi iPhone → ScanForge):

- fotos HEIC (Objeto Pro / Fotos 48 MP) — es lo que espera `mac-reconstruct --input`
- `Export/` — `*.usdz`, `*.stl`, `*.obj` (mm, Z arriba), `*-nube.ply` / `*-truedepth.ply`
- `Checkpoints/` — caché interna de Object Capture (no se sube al Mac)
- `scanforge-session.json` — metadatos

## Consejos de escaneo

- **Objeto Pro:** luz difusa, fondo que contraste, 2–3 pasadas a distintas alturas y
  «Girar y seguir» para capturar la base.
- **LiDAR Fusión:** toca el objeto para fijar la zona y rodéalo a 30–60 cm. Las zonas
  sin malla gris todavía no están cubiertas.
- **Micro TrueDepth:** iPhone en un soporte con la pantalla hacia ti y el objeto en una
  plataforma giratoria a 20–40 cm. Gira unos 20°/s. Si el borde de la vista de cámara
  se pone rojo, el seguimiento se ha perdido: vuelve un poco atrás. Usa spray mate en
  piezas brillantes o negras.
