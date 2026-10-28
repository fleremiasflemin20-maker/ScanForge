# Cómo funcionan los escáneres 3D comerciales y cómo los replica ScanForge Pro

Investigación de octubre de 2026 sobre las tecnologías de los escáneres de consumo y
profesionales, y cómo cada una se traslada a los sensores del iPhone 17 Pro.

## Qué usan las marcas líderes

| Escáner | Tecnología de captura | Seguimiento | Precisión anunciada | Procesado |
|---|---|---|---|---|
| **Creality CR-Scan Raptor Pro** | Híbrido: 22 líneas láser azules en cruz + 7 paralelas, y luz estructurada **NIR binocular** | Marcadores (láser) / geometría y textura (NIR) | 0,02 mm + 0,06 mm/m; hasta 60 fps en láser, 20 fps en NIR | PC (Windows/macOS) por USB-C |
| **Bambu Lab S1** (anunciado para noviembre de 2026) | Escáner de mano con varias cámaras. Desarrollado con SCANTECH/SCANOLOGY (fabricante de escáneres láser industriales) | No publicado | No publicado | Se espera integración con Bambu Studio |
| **Revopoint MIRACO** | Luz estructurada NIR con proyector de puntos + cámara RGB | Geometría + textura | Hasta 0,05 mm | **Autónomo**: ordenador y pantalla integrados, sin PC |
| **Revopoint MetroX** | Láser azul (líneas cruzadas/paralelas) | Marcadores | ~0,025 mm | PC |
| **Shining 3D EinScan Rigil** | Multimodo, inalámbrico | Híbrido | Gama profesional | Integrado / PC |
| **Artec Eva / Leo / Spider II** | Luz estructurada blanca/azul | Geometría + textura, sin marcadores | Gama metrológica (≈0,01–0,1 mm) | Leo: integrado; Eva: PC |
| **3DMakerpro Seal / Moose** | Luz estructurada | Geometría / marcadores | Seal: hasta 0,01 mm en un área pequeña | PC |

### Las cinco ideas clave que comparten

1. **Medir distancia proyectando luz conocida.** Láser azul (líneas finas, poco
   afectado por la luz ambiente, máxima precisión) o patrones infrarrojos NIR (más
   rápido, mejor con piel y colores oscuros). La cámara ve cómo se deforma el patrón y
   calcula la profundidad por triangulación.
2. **Seguimiento sin marcadores.** Cada fotograma de profundidad se alinea con el modelo
   que ya existe (ICP, *Iterative Closest Point*) usando la geometría y la textura. Los
   marcadores adhesivos solo hacen falta en superficies planas o simétricas.
3. **Fusión en tiempo real.** Las mediciones se promedian en una rejilla de vóxeles
   (TSDF o similar). El ruido se cancela y ves el modelo crecer en pantalla.
4. **Textura RGB aparte.** Una cámara a color tomada a la vez colorea la malla.
5. **Escala real.** Al medir distancias, el modelo sale en milímetros, sin calibrar a mano.

## Cómo lo trasladamos al iPhone 17 Pro

| Tecnología del escáner | Sensor del iPhone | Modo de ScanForge Pro |
|---|---|---|
| Luz estructurada NIR (Raptor en modo NIR, Revopoint) | **TrueDepth**: proyector de puntos infrarrojos + cámara IR (Face ID) | **Micro TrueDepth**: profundidad filtrada, eliminación de la plataforma por RANSAC, seguimiento ICP punto-a-plano, fusión en vóxeles de 0,5 a 2 mm |
| Seguimiento híbrido + rango largo | **LiDAR** dToF + seguimiento visual-inercial de ARKit | **LiDAR Fusión**: nube en tiempo real con mapa de confianza, zona de escaneo, malla LiDAR exportada a STL |
| Cámara RGB de textura + fotogrametría | Cámara principal de **48 MP** + LiDAR para la escala | **Objeto Pro**: Object Capture guiado con reconstrucción **en el iPhone** (como el MIRACO, sin PC) |
| Escaneo de alto detalle offline | Fotos a resolución completa | **Fotos 48 MP** → `mac-reconstruct` en el Mac |
| Exportar a escala para el slicer | — | STL/OBJ en **mm con Z arriba**; PLY → malla con `mesh-prep` (Poisson) |

### Expectativas realistas

- **El láser azul no tiene equivalente en el iPhone.** Para detalles por debajo de
  ~0,1 mm (roscas, texto grabado fino) un Raptor/MetroX seguirá siendo superior.
- **Objeto Pro** suele dar el mejor resultado global en objetos con textura: la
  fotogrametría de 48 MP captura detalle fino y el LiDAR fija la escala.
- **Micro TrueDepth** funciona mejor con piezas de 3 a 20 cm a 20–40 cm de distancia.
  Como cualquier escáner de luz estructurada, falla con negro brillante, cromo y vidrio:
  usa spray de escaneo, como con un escáner comercial.
- **LiDAR Fusión** tiene una resolución nativa baja (256×192). Es ideal para piezas
  grandes, muebles, personas y espacios, no para detalle fino.

Fuentes: listados técnicos de Creality Raptor Pro (MatterHackers, 3DJake, Filament2Print),
cobertura de Bambu Lab S1 (Tom's Hardware, 3DNatives, All3DP, octubre de 2026),
comparativas de 2026 de Revopoint, DigitalCameraWorld y 3DTechValley, y la sesión
WWDC23 «Meet Object Capture for iOS» de Apple.
