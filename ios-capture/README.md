# ios-capture

App en SwiftUI (iOS 17+) para capturar las fotos que luego procesa `mac-reconstruct`.

- **Con LiDAR** (tu iPhone 17 Pro, y cualquier Pro desde el 12 Pro): usa
  `ObjectCaptureSession` + `ObjectCaptureView` (RealityKit) — Apple se encarga de la
  UI de guía (detección del objeto, ángulos, aviso de "dale la vuelta").
- **Sin LiDAR**: modo manual con AVFoundation — vista de cámara propia con una guía
  visual de 3 alturas y contador de fotos (12 fotos sugeridas por altura, ~cada 30°).

La detección es automática en tiempo de ejecución (`ObjectCaptureSession.isSupported`),
así la misma app funciona igual en cualquier iPhone.

## Abrir el proyecto

Este repo no incluye un `.xcodeproj` (se generan con XcodeGen para no versionar XML
binario-ish propenso a conflictos). En tu Mac:

```bash
brew install xcodegen
cd ios-capture
xcodegen generate
open ScanForge.xcodeproj
```

En Xcode, en el target `ScanForge` → *Signing & Capabilities*, pon tu Team para poder
instalar en el iPhone (los simuladores no tienen cámara ni LiDAR, hace falta dispositivo real).

## Estructura

```
Sources/
  ScanForgeApp.swift          punto de entrada
  ContentView.swift           pantalla principal: nombre del objeto, iniciar captura, subir
  Capture/
    CaptureCoordinator.swift     decide LiDAR vs manual
    LiDARCaptureView.swift       ObjectCaptureSession/ObjectCaptureView
    ManualCaptureController.swift  AVFoundation: sesión de cámara, captura de fotos
    ManualCaptureView.swift       UI del modo manual (guía de 3 alturas + contador)
    CaptureExporter.swift         metadatos de la sesión (scanforge-session.json)
  Networking/
    MacUploader.swift          Fase 3: sube la carpeta al Mac por la red local
  Models/
    CaptureSession.swift       modelo de sesión + carpeta de almacenamiento
```

## Carpeta de salida

Cada sesión se guarda en `Documents/ScanForgeCaptures/<objeto>-<timestamp>/` dentro del
sandbox de la app, con las fotos (y en modo LiDAR, profundidad/gravedad que escribe
`ObjectCaptureSession` directamente) más un `scanforge-session.json` con metadatos.
Esa carpeta es justo lo que espera `--input` en `mac-reconstruct`.

Para sacarla del iPhone hoy: Files app → On My iPhone → ScanForge → AirDrop/Cable a tu
Mac. La subida automática por red local (botón "Subir al Mac") es la Fase 3, y necesita
el receptor `scripts/receive_uploads.py` corriendo en el Mac (ver `scripts/README.md`).

## Limitaciones / pendiente de probar en dispositivo

Este código no se pudo compilar ni probar en este entorno (se escribió desde Windows,
sin Xcode). Antes de confiar en él:

1. Compílalo en Xcode y revisa los nombres exactos de la API de `ObjectCaptureSession`
   / `ObjectCaptureView` contra la documentación de tu versión de Xcode — la forma
   general (estado `.ready/.detecting/.capturing/.completed`, `start(imagesDirectory:)`,
   `beginNewScanPassAfterFlip()`) es la de WWDC23 "Meet Object Capture for iOS", pero
   Apple ha ajustado detalles entre versiones de iOS.
2. Prueba el modo manual en un iPhone real (la vista previa de cámara y el flujo de
   captura no se pueden probar en el simulador).
3. La subida por red (`MacUploader`) asume un receptor Bonjour `_scanforge._tcp`
   corriendo en el Mac; sin él, solo vas a ver "no se encontró ningún Mac".
