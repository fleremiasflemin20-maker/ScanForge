# mac-reconstruct

CLI en Swift para macOS (Apple Silicon, macOS 14+) que usa `PhotogrammetrySession`
(RealityKit / Object Capture) para reconstruir una malla 3D a partir de una carpeta
de fotos.

## Build

```bash
cd mac-reconstruct
swift build -c release
```

El binario queda en `.build/release/mac-reconstruct`.

## Uso

```bash
.build/release/mac-reconstruct \
  --input ~/ScanForge/captures/jarron-001 \
  --output ~/ScanForge/reconstructions/jarron-001 \
  --detail full \
  --feature-sensitivity normal \
  --object-masking
```

Produce `model.usdz` y `model.obj` dentro de la carpeta de salida.

### Opciones

| Flag | Valores | Default | Notas |
|---|---|---|---|
| `--input` | ruta a carpeta | — | Carpeta con HEIC/JPG (y profundidad embebida si la capturó `ios-capture` con LiDAR) |
| `--output` | ruta a carpeta | — | Se crea si no existe |
| `--detail` | preview, reduced, medium, full, raw | `full` | `raw` es el más lento y pesado; úsalo solo si necesitas máxima resolución |
| `--feature-sensitivity` | normal, high | `normal` | `high` ayuda con objetos texturizados/pequeños a costa de más tiempo de proceso |
| `--object-masking` | flag | desactivado | Requiere máscaras `<nombre>_mask.HEIC` junto a cada foto para aislar el objeto del fondo |

## Errores comunes

- **Pocas imágenes / poca superposición**: PhotogrammetrySession necesita típicamente
  20–40+ fotos con 60–70% de solape entre consecutivas. El CLI avisa si detecta menos
  de 10 imágenes, pero puede seguir fallando con más si la cobertura angular es mala
  (p.ej. solo fotos de un lado del objeto).
- **`stitchingIncomplete`**: el modelo no cerró en una sola pieza continua — normalmente
  faltan fotos de alguna cara del objeto (parte de arriba, abajo, o un lateral).
- **Hardware no soportado**: se requiere Mac con Apple Silicon; `PhotogrammetrySession.isSupported`
  se comprueba antes de arrancar.
