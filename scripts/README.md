# scripts

## scanforge.sh

Orquestador de punta a punta. Corre en el Mac Mini.

```bash
chmod +x scanforge.sh
./scanforge.sh \
  --input ~/ScanForge/captures/jarron-001 \
  --name jarron-001 \
  --height-mm 180 \
  --detail full
```

Encadena `mac-reconstruct` (fotos → USDZ/OBJ) y `mesh-prep` (OBJ → 3MF/STL listo para
imprimir) usando `~/ScanForge/{reconstructions,printable}/<nombre>` como carpetas de
trabajo (configurable con `--workdir`). Si los binarios no están en el `PATH`, indica
sus rutas con las variables de entorno `MAC_RECONSTRUCT_BIN` y `MESH_PREP_BIN`.

## receive_uploads.py

Receptor para la Fase 3 de `ios-capture`: escucha en la red local y recibe las
sesiones que el iPhone sube con el botón "Subir al Mac".

```bash
pip install zeroconf
python3 receive_uploads.py --captures-dir ~/ScanForge/captures --port 5050
```

Sin el paquete `zeroconf` el servidor funciona igual, pero el iPhone no podrá
descubrirlo por Bonjour (tendrías que adaptar `MacUploader.swift` para conectar por IP
fija). Cada sesión recibida queda en `~/ScanForge/captures/<objeto>-<timestamp>/`,
lista para pasarle a `scanforge.sh --input`.

### Flujo completo con subida automática

```bash
# Terminal 1: deja el receptor corriendo
python3 receive_uploads.py --captures-dir ~/ScanForge/captures

# Desde el iPhone: capturas y pulsas "Subir al Mac"

# Terminal 2: cuando termine la subida, procesas esa carpeta
./scanforge.sh --input ~/ScanForge/captures/jarron-001-20250101T120000 --name jarron-001 --height-mm 180
```

No hay disparo automático del pipeline tras la subida a propósito: la escala real
(`--height-mm`/`--width-mm`/`--depth-mm`/`--scale`) es algo que solo tú sabes del
objeto, así que ese paso se queda manual.
