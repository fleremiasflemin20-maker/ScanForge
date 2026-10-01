# mesh-prep

Pipeline en Python que convierte el OBJ/USDZ que produce `mac-reconstruct` en una
malla lista para imprimir, sin retoques manuales: 3MF + STL, watertight, escalada a
milímetros reales y con un tamaño de polígonos razonable.

## Instalación

Requiere Python 3.11+.

```bash
cd mesh-prep
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Uso

```bash
mesh-prep \
  --input ~/ScanForge/reconstructions/jarron-001/model.obj \
  --output ~/ScanForge/printable/jarron-001 \
  --height-mm 180 \
  --target-triangles 200000
```

Genera en la carpeta de salida:
- `model.3mf` (preferido para Creality Print)
- `model.stl`
- `model.report.json`

### Opciones

| Flag | Descripción |
|---|---|
| `--input` | OBJ o USDZ de entrada |
| `--output` | carpeta de salida |
| `--height-mm` / `--width-mm` / `--depth-mm` / `--scale` | exactamente una, para fijar la escala real |
| `--target-triangles` | triángulos objetivo tras decimar (default 200000) |
| `--infill` | relleno 0-1 usado para estimar el peso de filamento (default 0.2) |
| `--density` | densidad del filamento en g/cm³ (default 1.24, PLA) |
| `--max-hole-size` | tamaño máx. de agujero (en aristas) a rellenar automáticamente (default 500) |
| `--skip-plane-removal` | omite la detección/corte del plano de mesa (úsalo si ya capturaste el objeto aislado, p.ej. con `--object-masking` en mac-reconstruct) |

## Qué hace el pipeline, paso a paso

1. **Carga** el OBJ (o convierte el USDZ a OBJ con `usd-core`, y si no está disponible, con Blender headless).
2. **Quita fragmentos sueltos**: separa componentes conectados y se queda con el más grande (volumen si es watertight, área si no).
3. **Detecta el plano de mesa/soporte**: agrupa caras por (normal, desplazamiento) para encontrar la región plana más grande que además esté en un extremo de la nube de puntos — eso es la mesa, no una cara plana del propio objeto. Si no encuentra nada suficientemente grande y extremo (p.ej. el objeto ya vino aislado), simplemente no corta nada.
4. **Orienta** la malla para que la normal de ese plano pase a ser +Z, y **corta** todo lo que quede en o debajo de él.
5. **Genera una base plana**: encuentra el borde abierto que dejó el corte y lo tapa con un parche plano en Z=0 (en vez de un relleno de agujero orgánico, que dejaría una base irregular).
6. **Rellena agujeros restantes** (ruido de escaneo) y **repara no-manifold** con pymeshlab; **verifica watertight y winding consistente** con trimesh.
7. **Escala** a milímetros según la dimensión conocida que hayas indicado.
8. **Centra** la pieza en X/Y y la apoya en Z=0.
9. **Decima** a trimesh.`target-triangles` con quadric edge collapse (pymeshlab) si hace falta.
10. **Exporta** 3MF + STL y escribe el **reporte JSON**.

### Limitaciones conocidas

- La detección del plano de mesa asume que la mesa/tornamesa tiene suficiente textura
  como para que PhotogrammetrySession la reconstruya con detalle (una superficie lisa
  y sin patrón puede no reconstruirse bien y entonces no hay nada que detectar — en ese
  caso usa `--object-masking` al capturar/reconstruir y `--skip-plane-removal` aquí).
- Si tras la reparación la malla sigue sin ser watertight, el reporte lo indica
  (`is_watertight: false`) y el volumen/peso estimados pasan a ser una aproximación
  por convex hull. Creality Print suele poder repararlo igualmente, pero no es
  garantía de una impresión correcta.
- El peso estimado es `volumen × densidad × relleno`: una aproximación rápida, no el
  cálculo real de un slicer (que separa paredes/perímetros del relleno interior).

## Tests

```bash
pip install -e ".[dev]"  # o: pip install pytest
pytest
```

Los tests generan mallas sintéticas (objeto + mesa, con fragmentos sueltos y agujeros
de ruido) y verifican que el pipeline completo produce una malla watertight, con las
dimensiones y el conteo de triángulos esperados — no dependen de un escaneo real.
