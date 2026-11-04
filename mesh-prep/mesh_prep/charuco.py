"""Escala y orientación exactas con un tablero ChArUco en el plato giratorio.

Una sola medida con calibre deja la escala sin fijar en las otras direcciones. Con
un tablero de medidas conocidas bajo la pieza (gira con ella):

1. Se detectan las esquinas ChArUco en cada foto (precisión subpíxel).
2. Con esas mismas fotos se calibra la cámara (intrínsecos + distorsión) y se obtiene
   la posición de la cámara en milímetros respecto al tablero (solvePnP).
3. Se comparan esas posiciones con las que calculó la fotogrametría
   (`mac-reconstruct --poses`) y una semejanza de Umeyama da escala, rotación y
   traslación. El residuo es la comprobación de la escala (*check distance*).

El resultado (`charuco-transform.json`) lleva el modelo a milímetros reales con el
plano del tablero en Z=0 y Z hacia arriba. Uso:

    python -m mesh_prep.charuco board --output tablero.png          # imprimir
    python -m mesh_prep.charuco solve --images fotos/ --poses poses.json --output t.json
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

# Tablero para A4 (160 × 160 mm, cabe con los márgenes de cualquier impresora). Si
# cambias estas medidas, imprime y mide de nuevo.
SQUARES = (10, 10)
SQUARE_MM = 16.0
MARKER_MM = 12.0
DICTIONARY = cv2.aruco.DICT_5X5_250
MIN_CORNERS = 8


def make_board(square_mm: float = SQUARE_MM, marker_mm: float = MARKER_MM) -> cv2.aruco.CharucoBoard:
    dictionary = cv2.aruco.getPredefinedDictionary(DICTIONARY)
    return cv2.aruco.CharucoBoard(SQUARES, square_mm, marker_mm, dictionary)


def board_image(dpi: int = 300, square_mm: float = SQUARE_MM, marker_mm: float = MARKER_MM) -> np.ndarray:
    """Imagen del tablero a tamaño real para `dpi`, con una regla de control: al
    imprimir, mide un cuadro con el calibre (debe dar exactamente `square_mm`)."""
    board = make_board(square_mm, marker_mm)
    px_per_mm = dpi / 25.4
    side = int(round(SQUARES[0] * square_mm * px_per_mm))
    img = board.generateImage((side, side), marginSize=0, borderBits=1)
    margin = int(15 * px_per_mm)
    canvas = np.full((side + 2 * margin, side + 2 * margin), 255, np.uint8)
    canvas[margin:margin + side, margin:margin + side] = img
    text = f"ScanForge ChArUco - cuadro {square_mm:g} mm - imprimir al 100%"
    cv2.putText(canvas, text, (margin, margin + side + int(9 * px_per_mm)),
                cv2.FONT_HERSHEY_SIMPLEX, px_per_mm * 0.22, 0, max(1, int(px_per_mm * 0.3)))
    return canvas


def detect(image: np.ndarray, board: cv2.aruco.CharucoBoard) -> tuple[np.ndarray, np.ndarray] | None:
    """(puntos 3D del tablero en mm, puntos 2D en píxeles) o None si hay pocos."""
    gray = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    corners, ids, _, _ = cv2.aruco.CharucoDetector(board).detectBoard(gray)
    if ids is None or len(ids) < MIN_CORNERS:
        return None
    obj, img = board.matchImagePoints(corners, ids)
    if obj is None or len(obj) < MIN_CORNERS:
        return None
    return obj.reshape(-1, 3).astype(np.float32), img.reshape(-1, 2).astype(np.float32)


def load_gray(path: Path, max_side: int | None = None) -> np.ndarray:
    from PIL import Image, ImageOps
    from pillow_heif import register_heif_opener

    register_heif_opener()
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("L")
        if max_side:
            im.thumbnail((max_side, max_side))
        return np.asarray(im)


@dataclass
class BoardViews:
    names: list[str]
    centers_mm: np.ndarray  # centro de cada cámara en el sistema del tablero (mm)
    reprojection_px: float
    camera_matrix: np.ndarray


def focal_from_35mm(f35: float, size: tuple[int, int]) -> float:
    """Focal en píxeles a partir de la focal equivalente de 35 mm del EXIF (se define
    sobre la diagonal: 43,27 mm)."""
    return f35 * float(np.hypot(*size)) / 43.27


def camera_centers(images: dict[str, np.ndarray], board: cv2.aruco.CharucoBoard,
                   focal_px: float | None = None) -> BoardViews:
    detections = {name: d for name, img in images.items() if (d := detect(img, board)) is not None}
    if len(detections) < 6:
        raise ValueError(f"El tablero ChArUco solo se vio bien en {len(detections)} fotos (mínimo 6).")
    names = sorted(detections)
    obj = [detections[n][0] for n in names]
    img = [detections[n][1] for n in names]
    size = next(iter(images.values())).shape[1::-1]
    # Con vistas de un plato giratorio la calibración libre es casi degenerada (focal
    # y distancia se confunden): partimos de la focal del EXIF (24 mm equivalentes del
    # gran angular del iPhone si no hay) y fijamos proporción y centro óptico.
    focal = focal_px or focal_from_35mm(24.0, size)
    k0 = np.array([[focal, 0, size[0] / 2], [0, focal, size[1] / 2], [0, 0, 1]])
    flags = (cv2.CALIB_USE_INTRINSIC_GUESS | cv2.CALIB_FIX_ASPECT_RATIO
             | cv2.CALIB_FIX_PRINCIPAL_POINT | cv2.CALIB_ZERO_TANGENT_DIST)
    rms, k, dist, rvecs, tvecs = cv2.calibrateCamera(obj, img, size, k0, None, flags=flags)
    centers = []
    for rvec, tvec in zip(rvecs, tvecs):
        r, _ = cv2.Rodrigues(rvec)
        centers.append((-r.T @ tvec).ravel())
    # OpenCV pone Z del tablero hacia dentro: lo giramos para que Z apunte a la cámara.
    flip = np.diag([1.0, -1.0, -1.0])
    return BoardViews(names, np.array(centers) @ flip.T, float(rms), k)


def umeyama(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    """Semejanza (s, R, t) que minimiza |dst - (s R src + t)|²."""
    mu_s, mu_d = src.mean(axis=0), dst.mean(axis=0)
    xs, xd = src - mu_s, dst - mu_d
    cov = xd.T @ xs / len(src)
    u, d, vt = np.linalg.svd(cov)
    s_fix = np.eye(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        s_fix[2, 2] = -1
    rot = u @ s_fix @ vt
    scale = float(np.trace(np.diag(d) @ s_fix) / xs.var(axis=0).sum())
    return scale, rot, mu_d - scale * rot @ mu_s


def _quat_matrix(q: list[float]) -> np.ndarray:
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def solve(views: BoardViews, poses: dict[str, dict]) -> dict:
    """Transformación reconstrucción → milímetros del tablero, más su verificación."""
    common = [n for n in views.names if n in poses]
    if len(common) < 6:
        raise ValueError(f"Solo {len(common)} fotos tienen a la vez tablero y pose (mínimo 6).")
    dst = np.array([views.centers_mm[views.names.index(n)] for n in common])
    # RealityKit da la pose de la cámara; por si acaso probamos también la inversa.
    candidates = {
        "camara_a_mundo": np.array([poses[n]["t"] for n in common]),
        "mundo_a_camara": np.array([-_quat_matrix(poses[n]["q"]).T @ np.array(poses[n]["t"]) for n in common]),
    }
    best = None
    for kind, src in candidates.items():
        s, r, t = umeyama(src, dst)
        residual = np.linalg.norm(dst - (s * src @ r.T + t), axis=1)
        if best is None or residual.mean() < best[4].mean():
            best = (kind, s, r, t, residual)
    kind, s, r, t, residual = best
    matrix = np.eye(4)
    matrix[:3, :3] = s * r
    matrix[:3, 3] = t
    spread = float(np.linalg.norm(dst - dst.mean(axis=0), axis=1).mean())
    return {
        "matriz": matrix.tolist(),
        "escala": s,
        "fotos": len(common),
        "residuo_medio_mm": round(float(residual.mean()), 3),
        "error_escala_estimado": round(float(residual.mean()) / spread, 5),
        "reproyeccion_px": round(views.reprojection_px, 3),
        "convenio_pose": kind,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="scanforge-charuco", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("board", help="Generar el tablero para imprimir.")
    b.add_argument("--output", required=True, help="PNG o PDF de salida.")
    b.add_argument("--dpi", type=int, default=300)
    s = sub.add_parser("solve", help="Calcular escala y orientación de una reconstrucción.")
    s.add_argument("--images", required=True)
    s.add_argument("--poses", required=True, help="poses.json de mac-reconstruct --poses")
    s.add_argument("--output", required=True)
    args = parser.parse_args(argv)

    if args.cmd == "board":
        img = board_image(args.dpi)
        out = Path(args.output)
        if out.suffix.lower() == ".pdf":
            from PIL import Image
            Image.fromarray(img).save(out, resolution=args.dpi)
        else:
            cv2.imwrite(str(out), img)
        print(f"Tablero guardado en {out}. Imprímelo al 100 % y comprueba con el calibre que un cuadro mide {SQUARE_MM:g} mm.")
        return 0

    folder = Path(args.images)
    exts = {".heic", ".heif", ".jpg", ".jpeg", ".png"}
    paths = [p for p in sorted(folder.iterdir()) if p.suffix.lower() in exts and not p.stem.endswith("_mask")]
    images = {p.name: load_gray(p) for p in paths}
    focal_px = None
    if paths:
        from PIL import Image
        from pillow_heif import register_heif_opener

        register_heif_opener()
        with Image.open(paths[0]) as im:
            f35 = im.getexif().get_ifd(0x8769).get(41989)  # FocalLengthIn35mmFilm
        if f35:
            focal_px = focal_from_35mm(float(f35), next(iter(images.values())).shape[1::-1])
    poses = json.loads(Path(args.poses).read_text())
    try:
        result = solve(camera_centers(images, make_board(), focal_px), poses)
    except ValueError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1
    Path(args.output).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"ChArUco: escala x{result['escala']:.5g} con {result['fotos']} fotos, "
          f"residuo {result['residuo_medio_mm']} mm (error de escala ≈ {result['error_escala_estimado']:.2%})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
