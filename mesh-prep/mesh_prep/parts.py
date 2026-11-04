"""División de una pieza escaneada en partes imprimibles que encajan, con las mismas
técnicas que los programas de CAD y los slicers ("Split Body" de Fusion 360, "Cut"
con conectores de Bambu Studio):

- **Por forma / anatomía** (`segment_by_shape` + `split_planar`): descomposición en
  partes casi convexas (CoACD), que separa por donde la pieza se estrecha (cuello,
  hombros, muñecas, tobillos). En cada unión se ajusta un plano y se corta **solo esa
  extremidad** con ese plano: la cara de corte queda perfectamente plana.
- **Por colores** (`segment_by_color` + `split_by_labels`): cada triángulo toma el
  color de la textura, los colores se agrupan en CIELAB (pelo, piel, ojos, ropa…) y
  la frontera entre partes sigue el borde del color, suavizada.
- **Corte por plano** (`plane_cut`): un corte manual exacto, como en el slicer.
- **Encajes** (`connect`): pivote hexagonal con punta achaflanada en una parte y
  agujero con holgura en la otra (no gira y entra sin forzar), o espiga suelta con
  agujero en ambas partes.

Todos los cortes son booleanos de Manifold (el motor de OpenSCAD y Blender) y se
hacen en secuencia (parte = resto ∩ región; resto = resto − región): la suma de las
partes es exactamente la pieza original, sin huecos ni solapes. La superficie
exterior es la del escaneo; solo se generan las caras de corte.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import manifold3d as mf
import numpy as np
import trimesh
from scipy import ndimage, sparse
from scipy.cluster.vq import kmeans2
from scipy.spatial import cKDTree

# Holgura de encaje por defecto: típica para PLA/PETG en una impresora calibrada.
CLEARANCE_MM = 0.2
CONNECTORS = ("pivote", "espiga", "ninguno")


# ---------------------------------------------------------------------------
# Conversión trimesh <-> Manifold


def to_manifold(mesh: trimesh.Trimesh) -> mf.Manifold:
    m = mf.Manifold(mf.Mesh(vert_properties=np.ascontiguousarray(mesh.vertices, dtype=np.float32),
                            tri_verts=np.ascontiguousarray(mesh.faces, dtype=np.uint32)))
    if m.status() != mf.Error.NoError:
        raise ValueError(f"La malla no es un sólido cerrado válido ({m.status()}): pásala antes por mesh-prep.")
    return m


def to_trimesh(manifold: mf.Manifold) -> trimesh.Trimesh:
    # Sin `process`: Manifold ya entrega una topología cerrada por índices; fusionar
    # vértices cercanos puede romperla en aristas muy finas.
    mesh = manifold.to_mesh()
    return trimesh.Trimesh(vertices=np.asarray(mesh.vert_properties)[:, :3],
                           faces=np.asarray(mesh.tri_verts), process=False)


# ---------------------------------------------------------------------------
# Etiquetas por triángulo


def face_colors(mesh: trimesh.Trimesh) -> np.ndarray | None:
    """Color RGB (0–1) de cada triángulo (textura o colores por vértice/cara)."""
    visual = mesh.visual
    if visual is None:
        return None
    if visual.kind == "texture":
        try:
            visual = visual.to_color()
        except Exception:
            return None
    if visual.kind == "face":
        return np.asarray(visual.face_colors, dtype=np.float64)[:, :3] / 255.0
    if visual.kind == "vertex":
        vc = np.asarray(visual.vertex_colors, dtype=np.float64)[:, :3] / 255.0
        return vc[mesh.faces].mean(axis=1)
    return None


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """sRGB (0–1) → CIELAB (D65): las distancias se parecen a lo que percibe el ojo."""
    c = np.where(rgb > 0.04045, ((rgb + 0.055) / 1.055) ** 2.4, rgb / 12.92)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz /= np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.column_stack([116 * f[:, 1] - 16, 500 * (f[:, 0] - f[:, 1]), 200 * (f[:, 1] - f[:, 2])])


def _face_graph(mesh: trimesh.Trimesh) -> sparse.csr_matrix:
    adj = mesh.face_adjacency
    n = len(mesh.faces)
    rows = np.concatenate([adj[:, 0], adj[:, 1]])
    cols = np.concatenate([adj[:, 1], adj[:, 0]])
    return sparse.csr_matrix((np.ones(len(rows)), (rows, cols)), shape=(n, n))


def clean_labels(mesh: trimesh.Trimesh, labels: np.ndarray, smooth_iterations: int = 4,
                 min_area_fraction: float = 0.0005) -> np.ndarray:
    """Votación entre triángulos vecinos (quita el moteado de la textura) y fusión de
    islas diminutas con la zona con la que más borde comparten."""
    labels = np.asarray(labels).copy()
    graph = _face_graph(mesh)
    n = len(labels)
    for _ in range(smooth_iterations):
        k = int(labels.max()) + 1
        onehot = sparse.csr_matrix((np.ones(n), (np.arange(n), labels)), shape=(n, k))
        labels = np.asarray((graph @ onehot + onehot * 1.5).argmax(axis=1)).ravel()

    min_area = mesh.area * min_area_fraction
    rows, cols = graph.nonzero()
    for _ in range(10):
        same = labels[rows] == labels[cols]
        islands = sparse.csr_matrix((np.ones(same.sum()), (rows[same], cols[same])), shape=graph.shape)
        n_comp, comp = sparse.csgraph.connected_components(islands, directed=False)
        comp_area = np.bincount(comp, weights=mesh.area_faces, minlength=n_comp)
        changed = False
        for c in np.where(comp_area < min_area)[0]:
            faces = np.where(comp == c)[0]
            neighbors = graph[faces].indices
            neighbors = neighbors[comp[neighbors] != c]
            if len(neighbors):
                labels[faces] = np.bincount(labels[neighbors]).argmax()
                changed = True
        if not changed:
            break
    return np.unique(labels, return_inverse=True)[1]


def segment_by_color(mesh: trimesh.Trimesh, n_colors: int, colors: np.ndarray | None = None,
                     seed: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """(etiqueta por triángulo, color RGB medio de cada etiqueta)."""
    rgb = face_colors(mesh) if colors is None else colors
    if rgb is None:
        raise ValueError("La malla no tiene color: usa el escaneo texturizado o divide por forma.")
    lab = rgb_to_lab(rgb)
    rng = np.random.default_rng(seed)
    p = mesh.area_faces / mesh.area_faces.sum()
    sample = lab[rng.choice(len(lab), size=min(len(lab), 40_000), p=p)]
    centers, _ = kmeans2(sample, n_colors, minit="++", seed=seed)
    labels = clean_labels(mesh, cKDTree(centers).query(lab)[1])
    palette = np.array([np.average(rgb[labels == i], axis=0, weights=mesh.area_faces[labels == i])
                        for i in range(labels.max() + 1)])
    return labels, palette


def segment_by_shape(mesh: trimesh.Trimesh, max_parts: int = 10, concavity: float = 0.1) -> np.ndarray:
    """Etiqueta por triángulo según la parte casi convexa (CoACD) que lo contiene."""
    import coacd

    coacd.set_log_level("error")
    hulls = coacd.run_coacd(coacd.Mesh(mesh.vertices, mesh.faces), threshold=concavity,
                            max_convex_hull=max_parts, preprocess_mode="auto")
    centroids = mesh.triangles_center
    depth = np.full((len(centroids), len(hulls)), -np.inf)
    for i, (v, f) in enumerate(hulls):
        hull = trimesh.Trimesh(v, f, process=True).convex_hull
        offsets = (hull.face_normals * hull.triangles[:, 0]).sum(axis=1)
        # Distancia al interior del casco (positiva = dentro).
        depth[:, i] = (offsets[None, :] - centroids @ hull.face_normals.T).min(axis=1)
    return clean_labels(mesh, depth.argmax(axis=1), min_area_fraction=0.003)


class ColorCloud:
    """Puntos con el color de la textura del escaneo original. El pipeline rehace la
    malla (Poisson, decimado) y pierde la textura: esta nube se mueve con la pieza en
    cada paso rígido o de escala, y al final devuelve el color de cada triángulo."""

    def __init__(self, points: np.ndarray, colors: np.ndarray):
        self.points = np.asarray(points, dtype=np.float64)
        self.colors = np.asarray(colors, dtype=np.float64)

    @classmethod
    def from_mesh(cls, mesh: trimesh.Trimesh, count: int = 300_000) -> "ColorCloud | None":
        if mesh.visual is None or mesh.visual.kind not in ("texture", "vertex", "face"):
            return None
        try:
            if mesh.visual.kind == "texture":
                pts, _, rgba = trimesh.sample.sample_surface(mesh, count, sample_color=True, seed=0)
                rgb = np.asarray(rgba, dtype=np.float64)[:, :3] / 255.0
            else:
                fc = face_colors(mesh)
                pts, idx = trimesh.sample.sample_surface(mesh, count, seed=0)
                rgb = fc[idx]
        except Exception:
            return None
        return cls(pts, rgb)

    def apply(self, matrix: np.ndarray) -> None:
        self.points = trimesh.transform_points(self.points, np.asarray(matrix))

    def follow(self, before: trimesh.Trimesh, after: trimesh.Trimesh) -> None:
        """Aplica a la nube la semejanza que llevó `before` a `after` (mismos vértices)."""
        if len(before.vertices) != len(after.vertices) or len(before.vertices) < 3:
            return
        from .charuco import umeyama

        s, r, t = umeyama(np.asarray(before.vertices), np.asarray(after.vertices))
        self.points = s * self.points @ r.T + t

    def face_colors(self, mesh: trimesh.Trimesh) -> np.ndarray:
        _, idx = cKDTree(self.points).query(mesh.triangles_center, k=8, workers=-1)
        return np.median(self.colors[idx], axis=1)

    def save(self, path) -> None:
        np.savez_compressed(path, points=self.points.astype(np.float32), colors=self.colors.astype(np.float32))

    @classmethod
    def load(cls, path) -> "ColorCloud":
        data = np.load(path)
        return cls(data["points"], data["colors"])


# ---------------------------------------------------------------------------
# Regiones del espacio y partes


@dataclass
class Part:
    label: int
    mesh: trimesh.Trimesh
    color: np.ndarray | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def bodies(self) -> int:
        return len(to_manifold(self.mesh).decompose())


def _region_fields(mesh: trimesh.Trimesh, labels: np.ndarray, pitch: float):
    """Cada punto de una rejilla toma la etiqueta del triángulo más cercano."""
    lo = mesh.bounds[0] - 4 * pitch
    shape = np.ceil((mesh.bounds[1] + 4 * pitch - lo) / pitch).astype(int) + 1
    axes = [lo[i] + np.arange(shape[i]) * pitch for i in range(3)]
    grid = np.stack(np.meshgrid(*axes, indexing="ij"), axis=-1).reshape(-1, 3)
    nearest = labels[cKDTree(mesh.triangles_center).query(grid, workers=-1)[1]].reshape(shape)
    return nearest, lo


def _region_manifold(nearest: np.ndarray, lo: np.ndarray, pitch: float, labels,
                     dilate: int = 0) -> mf.Manifold | None:
    """Sólido de la zona del espacio cuyas etiquetas están en `labels`."""
    from skimage.measure import marching_cubes

    mask = np.isin(nearest, np.atleast_1d(labels))
    if dilate:
        mask = ndimage.binary_dilation(mask, iterations=dilate)
    values = ndimage.gaussian_filter(mask.astype(np.float32), sigma=1.0)
    values[[0, -1]] = 0
    values[:, [0, -1]] = 0
    values[:, :, [0, -1]] = 0
    if values.max() < 0.5:
        return None
    verts, faces, _, _ = marching_cubes(values, level=0.5, spacing=(pitch,) * 3)
    region = trimesh.Trimesh(verts + lo, faces[:, ::-1], process=True)
    if region.volume < 0:
        region.invert()
    try:
        return to_manifold(region)
    except ValueError:
        return None


def _absorb_fragments(pieces: list[mf.Manifold], min_fraction: float = 0.003) -> list[mf.Manifold]:
    """Los trocitos sueltos (láminas en las fronteras) se unen a la parte vecina con
    la que más contacto tienen, para que cada parte sea limpia."""
    total = sum(p.volume() for p in pieces)
    kept: list[list[mf.Manifold]] = [[] for _ in pieces]
    fragments = []
    for i, piece in enumerate(pieces):
        bodies = sorted(piece.decompose(), key=lambda b: -b.volume())
        for k, body in enumerate(bodies):
            if k == 0 or body.volume() >= total * min_fraction:
                kept[i].append(body)
            else:
                fragments.append(body)
    merged = [mf.Manifold.batch_boolean(bodies, mf.OpType.Add) if bodies else mf.Manifold() for bodies in kept]
    for frag in fragments:
        contact = [(m ^ _inflate(frag)).volume() if not m.is_empty() else 0.0 for m in merged]
        merged[int(np.argmax(contact))] = merged[int(np.argmax(contact))] + frag
    return merged


def _inflate(solid: mf.Manifold, factor: float = 1.02) -> mf.Manifold:
    """Copia ligeramente agrandada desde su centro (para medir contacto entre sólidos)."""
    lo, hi = np.array(solid.bounding_box()[:3]), np.array(solid.bounding_box()[3:])
    c = (lo + hi) / 2
    return solid.translate(tuple(-c)).scale((factor,) * 3).translate(tuple(c))


def split_by_labels(mesh: trimesh.Trimesh, labels: np.ndarray, palette: np.ndarray | None = None,
                    pitch: float | None = None) -> list[Part]:
    """Partes cuya frontera sigue el borde de las etiquetas (división por colores).

    Se usan regiones acumuladas (zona 1, zonas 1+2, …): cada frontera entre partes sale
    de una sola superficie, así no quedan rendijas ni solapes entre dos regiones."""
    pitch = pitch or float(mesh.extents.max()) / 300
    nearest, lo = _region_fields(mesh, labels, pitch)
    order = [int(x) for x in sorted(np.unique(labels), key=lambda lab: -mesh.area_faces[labels == lab].sum())]
    remaining = to_manifold(mesh)
    pieces, piece_labels = [], []
    for k, label in enumerate(order):
        cumulative = None if k == len(order) - 1 else _region_manifold(nearest, lo, pitch, order[:k + 1])
        if cumulative is None:
            piece, remaining = remaining, mf.Manifold()
        else:
            piece = remaining ^ cumulative
            remaining = remaining - cumulative
        if not piece.is_empty() and piece.volume() > 0:
            pieces.append(piece)
            piece_labels.append(label)
        if remaining.is_empty():
            break
    pieces = _absorb_fragments(pieces)
    return [Part(label, to_trimesh(piece), None if palette is None else palette[label])
            for label, piece in zip(piece_labels, pieces) if not piece.is_empty()]


def _label_tree(mesh: trimesh.Trimesh, labels: np.ndarray, root: int) -> dict[int, int]:
    """Padre de cada zona en el árbol de uniones que parte del cuerpo principal
    (BFS por la longitud de borde compartido): cabeza → cuello → torso, mano → brazo…"""
    adj = mesh.face_adjacency
    a, b = labels[adj[:, 0]], labels[adj[:, 1]]
    border = a != b
    lengths = np.linalg.norm(np.diff(mesh.vertices[mesh.face_adjacency_edges[border]], axis=1)[:, 0], axis=1)
    shared: dict[tuple[int, int], float] = {}
    for x, y, length in zip(a[border], b[border], lengths):
        key = (int(min(x, y)), int(max(x, y)))
        shared[key] = shared.get(key, 0.0) + float(length)
    parent = {root: root}
    frontier = [root]
    while frontier:
        nxt = []
        for node in frontier:
            for (x, y), _ in sorted(shared.items(), key=lambda kv: -kv[1]):
                other = y if x == node else x if y == node else None
                if other is not None and other not in parent:
                    parent[other] = node
                    nxt.append(other)
        frontier = nxt
    return parent


def _interface_plane(mesh: trimesh.Trimesh, labels: np.ndarray, label: int, parent: int):
    """Plano ajustado a la frontera entre `label` y su zona padre; la normal apunta
    hacia `label` (hacia la extremidad)."""
    adj = mesh.face_adjacency
    a, b = labels[adj[:, 0]], labels[adj[:, 1]]
    border = ((a == label) & (b == parent)) | ((a == parent) & (b == label))
    if border.sum() < 6:
        return None
    pts = mesh.vertices[mesh.face_adjacency_edges[border].reshape(-1)]
    center = pts.mean(axis=0)
    _, _, vt = np.linalg.svd(pts - center, full_matrices=False)
    normal = vt[2]
    inside = mesh.triangles_center[labels == label].mean(axis=0)
    if (inside - center) @ normal < 0:
        normal = -normal
    return center, normal


def _narrowest_offset(mesh: trimesh.Trimesh, center: np.ndarray, normal: np.ndarray,
                      back: float, forward: float, steps: int = 30) -> np.ndarray:
    """Desliza el plano de corte a lo largo de su normal hasta la sección más estrecha
    de la unión (el "cuello" real): ahí el corte es más pequeño y más limpio. Entre
    secciones casi iguales gana la más cercana al plano original."""
    from shapely.geometry import Point

    best_t, best_area = 0.0, np.inf
    # Se busca sobre todo hacia la extremidad (`forward`): el estrechamiento está ahí.
    for t in np.linspace(-back, forward, steps):
        origin = center + normal * t
        section = mesh.section(plane_origin=origin, plane_normal=normal)
        if section is None:
            continue
        planar, to_3d = section.to_2D()
        c2 = trimesh.transform_points([origin], np.linalg.inv(to_3d))[0][:2]
        polys = [p for p in planar.polygons_full if p.area > 0]
        if not polys:
            continue
        area = min(polys, key=lambda p: p.distance(Point(c2))).area
        if area < best_area * 0.97 or (area <= best_area * 1.03 and abs(t) < abs(best_t)):
            best_t, best_area = float(t), area
    return center + normal * best_t


def split_planar(mesh: trimesh.Trimesh, labels: np.ndarray, pitch: float | None = None,
                 min_thickness: float = 8.0) -> list[Part]:
    """División por forma con cortes planos: cada extremidad se separa de su zona padre
    por el plano ajustado a su unión, limitado a la zona de esa extremidad (no corta el
    resto de la figura). Se corta desde las puntas hacia dentro (cabeza antes que
    cuello), y el cuerpo principal (la zona mayor) se queda con el resto."""
    pitch = pitch or float(mesh.extents.max()) / 150
    nearest, lo = _region_fields(mesh, labels, pitch)
    areas = {int(lab): mesh.area_faces[labels == lab].sum() for lab in np.unique(labels)}
    body = max(areas, key=areas.get)
    parent = _label_tree(mesh, labels, body)

    def depth(lab: int) -> int:
        d = 0
        while lab != body and lab in parent:
            lab, d = parent[lab], d + 1
        return d

    remaining = to_manifold(mesh)
    pieces: list[mf.Manifold] = []
    info: list[tuple[int, int | None, tuple | None]] = []
    for label in sorted((lab for lab in parent if lab != body), key=lambda lab: (-depth(lab), areas[lab])):
        plane = _interface_plane(mesh, labels, label, parent[label])
        region = _region_manifold(nearest, lo, pitch, [label], dilate=3)
        if plane is None or region is None:
            continue
        center, normal = plane
        reach = float(np.ptp(mesh.triangles_center[labels == label] @ normal))
        center = _narrowest_offset(mesh, center, normal, back=min(reach * 0.2, 6.0),
                                   forward=min(reach * 0.6, 20.0))
        plane = (center, normal)
        cutter = region.trim_by_plane(tuple(normal), float(normal @ center))
        piece = remaining ^ cutter
        if piece.is_empty() or piece.volume() < mesh.volume * 0.002:
            continue
        # Una parte más fina que `min_thickness` (p. ej. un cuello cortísimo) no aloja
        # encajes y se rompería: se queda unida a su vecina.
        if np.ptp(to_trimesh(piece).vertices @ normal) < min_thickness:
            continue
        remaining = remaining - cutter
        pieces.append(piece)
        info.append((label, parent[label], plane))
    pieces.insert(0, remaining)
    info.insert(0, (body, None, None))
    pieces = _absorb_fragments(pieces)

    parts = []
    for (label, parent_label, plane), piece in zip(info, pieces):
        part = Part(label, to_trimesh(piece), notes=["cuerpo principal" if plane is None else "corte plano en la unión"])
        part.plane = plane  # type: ignore[attr-defined]
        part.parent_label = parent_label  # type: ignore[attr-defined]
        parts.append(part)
    return parts


# ---------------------------------------------------------------------------
# Encajes


def _prism(start: np.ndarray, end: np.ndarray, radius: float, sides: int = 6,
           tip_radius: float | None = None, tip_length: float = 0.0) -> mf.Manifold:
    """Prisma (hexagonal por defecto) de `start` a `end`; con `tip_radius` termina en
    un chaflán (cono truncado) para que entre sin forzar."""
    axis = end - start
    length = float(np.linalg.norm(axis))
    body_len = length - tip_length
    solid = mf.Manifold.cylinder(body_len, radius, radius, circular_segments=sides)
    if tip_radius is not None and tip_length > 0:
        tip = mf.Manifold.cylinder(tip_length, radius, tip_radius, circular_segments=sides)
        solid = solid + tip.translate((0, 0, body_len))
    rot = trimesh.geometry.align_vectors([0, 0, 1], axis / length)
    affine = np.array(rot[:3, :4], dtype=np.float64)
    affine[:, 3] = start
    return solid.transform(affine)


def _depth_inside(solid_mesh: trimesh.Trimesh, start: np.ndarray, direction: np.ndarray,
                  radius: float, max_len: float, wall: float = 1.2) -> float:
    """Cuánto puede entrar un conector de `radius` desde la cara de corte en
    `direction` dejando al menos `wall` mm de pared alrededor y al fondo."""
    direction = direction / np.linalg.norm(direction)
    helper = np.array([1.0, 0, 0]) if abs(direction[0]) < 0.9 else np.array([0, 1.0, 0])
    u = np.cross(direction, helper)
    u /= np.linalg.norm(u)
    v = np.cross(direction, u)
    angles = np.linspace(0, 2 * np.pi, 16, endpoint=False)
    ring = (np.cos(angles)[:, None] * u + np.sin(angles)[:, None] * v) * (radius + wall)
    best = 0.0
    for depth in np.linspace(0.5, max_len, 30):
        pts = np.vstack([start + direction * depth + ring, start + direction * (depth + wall)])
        if not solid_mesh.contains(pts).all():
            break
        best = float(depth)
    return best


def _cut_face(part: trimesh.Trimesh, center: np.ndarray, normal: np.ndarray):
    """Punto de la cara de corte más alejado del borde (polo de inaccesibilidad) y su
    distancia al borde: ahí cabe el conector más grueso."""
    from shapely.geometry import Point
    from shapely.ops import polylabel

    section = part.section(plane_origin=center, plane_normal=normal)
    if section is None:
        return None
    planar, to_3d = section.to_2D()
    polys = [p for p in planar.polygons_full if p.area > 0]
    if not polys:
        return None
    c2 = trimesh.transform_points([center], np.linalg.inv(to_3d))[0][:2]
    poly = min(polys, key=lambda p: p.distance(Point(c2)))
    spot = polylabel(poly, tolerance=0.05)
    room = poly.exterior.distance(spot)
    p3 = trimesh.transform_points([[spot.x, spot.y, 0.0]], to_3d)[0]
    return p3, float(room)


def connect(big: trimesh.Trimesh, small: trimesh.Trimesh, center: np.ndarray, normal: np.ndarray,
            kind: str = "pivote", clearance: float = CLEARANCE_MM, max_radius: float = 5.0,
            room_big: trimesh.Trimesh | None = None, room_small: trimesh.Trimesh | None = None,
            keep_out: list[tuple[np.ndarray, float]] | None = None,
            ) -> tuple[trimesh.Trimesh, trimesh.Trimesh, trimesh.Trimesh | None, str, float]:
    """Encaje entre dos partes unidas por la cara plana (center, normal → hacia `small`).

    - "pivote": prisma hexagonal unido a `big` con punta achaflanada; agujero con
      holgura en `small`. El hexágono impide que la parte gire.
    - "espiga": agujero en ambas partes y una espiga suelta (se imprime aparte).

    `room_big`/`room_small` son las partes sin conectores (para medir el espacio) y
    `keep_out` los puntos (y su radio) de otros conectores de `small` que el agujero
    no debe alcanzar.
    """
    room_big = big if room_big is None else room_big
    room_small = small if room_small is None else room_small
    if kind == "ninguno":
        return big, small, None, "sin encaje", 0.0
    # La sección se toma un poco dentro de `small`: justo en la cara de corte el plano
    # coincide con triángulos y la sección sale degenerada.
    face = _cut_face(room_small, center + normal * 0.05, normal)
    if face is None:
        return big, small, None, "no se encontró la cara de corte", 0.0
    spot, room = face
    # La sección se midió 0,05 mm dentro: el conector debe arrancar justo en el plano
    # del corte, o el agujero queda cerrado por una piel finísima.
    spot = spot - normal * float((spot - center) @ normal)
    # El mayor conector que cabe: se prueba de grueso a fino hasta que entra con pared
    # suficiente a lo largo de toda su longitud (un cuello se estrecha tras el corte).
    r = min(room * 0.5, max_radius)
    while r >= 1.0:
        depth_small = _depth_inside(room_small, spot, normal, r + clearance, r * 4)
        depth_big = _depth_inside(room_big, spot, -normal, r + clearance, r * 4)
        length = min(depth_small, r * 3)
        for point, reach in keep_out or []:
            # El agujero se detiene con pared antes de la base de otro conector.
            ahead = float((point - spot) @ normal)
            if ahead > 0:
                length = min(length, ahead - reach - 1.2 - clearance)
        if length >= r * 1.5 and (kind != "espiga" or depth_big >= r * 1.5):
            break
        r *= 0.85
    else:
        return big, small, None, "no cabe un encaje con pared suficiente en esta unión", 0.0
    # La holgura de un hexágono se mide entre caras: el radio del vértice crece /cos30°.
    hex_clear = clearance / np.cos(np.pi / 6)
    b, s = to_manifold(big), to_manifold(small)
    if kind == "pivote":
        base = min(r, depth_big)
        peg = _prism(spot - normal * base, spot + normal * length, r,
                     tip_radius=r * 0.75, tip_length=r * 0.4)
        hole = _prism(spot - normal * 0.01, spot + normal * (length + clearance), r + hex_clear)
        b, s = b + peg, s - hole
        loose = None
        reach = base
        note = f"pivote hexagonal {2 * r:.1f} mm × {length:.1f} mm, holgura {clearance} mm"
    else:
        depth = min(length, depth_big, r * 3)
        hole = _prism(spot - normal * (depth + clearance), spot + normal * (depth + clearance),
                      r + clearance / 2, sides=48)
        b, s = b - hole, s - hole
        reach = depth + clearance
        loose = to_trimesh(_prism(spot - normal * depth, spot + normal * depth, r, sides=48,
                                  tip_radius=r * 0.8, tip_length=r * 0.3))
        note = f"espiga Ø{2 * r:.1f} × {2 * depth:.1f} mm (imprimir aparte), holgura {clearance} mm"
    return to_trimesh(b), to_trimesh(s), loose, note, float(reach)


def plane_cut(mesh: trimesh.Trimesh, normal, offset: float, kind: str = "pivote",
              clearance: float = CLEARANCE_MM) -> list[Part]:
    """Corte exacto por el plano dot(normal, x) = offset, con encaje en la cara."""
    normal = np.asarray(normal, dtype=np.float64)
    normal /= np.linalg.norm(normal)
    top, bottom = to_manifold(mesh).split_by_plane(tuple(normal), float(offset))
    if top.is_empty() or bottom.is_empty():
        raise ValueError("El plano no corta la pieza.")
    top_m, bottom_m = to_trimesh(top), to_trimesh(bottom)
    # El pivote va en la mitad mayor, entrando en la menor.
    if bottom.volume() >= top.volume():
        big, small, n = bottom_m, top_m, normal
    else:
        big, small, n = top_m, bottom_m, -normal
    center = normal * offset
    big, small, loose, note, _ = connect(big, small, center, n, kind, clearance)
    parts = [Part(0, big, notes=[note]), Part(1, small, notes=[note])]
    if loose is not None:
        parts.append(Part(2, loose, notes=["espiga"]))
    return parts


# ---------------------------------------------------------------------------
# Flujo completo y exportación


def _parent_of(parts: list[Part], index: int, center: np.ndarray) -> int | None:
    """La parte (distinta de `index`) cuya superficie está más cerca del centro del
    corte: es con la que encaja."""
    best, best_d = None, np.inf
    for j, other in enumerate(parts):
        if j == index:
            continue
        d = float(np.abs(trimesh.proximity.signed_distance(other.mesh, [center])[0]))
        if d < best_d:
            best, best_d = j, d
    return best


def divide(mesh: trimesh.Trimesh, by: str = "shape", n_colors: int = 4, max_parts: int = 10,
           connector: str = "pivote", clearance: float = CLEARANCE_MM, log=print,
           colors: np.ndarray | None = None) -> list[Part]:
    """División completa: segmentar → cortar → encajes. `colors` (RGB por triángulo)
    sustituye a la textura de la malla, p. ej. desde una `ColorCloud`."""
    if by == "color":
        labels, palette = segment_by_color(mesh, n_colors, colors=colors)
        log(f"  {labels.max() + 1} zonas de color")
        # Para imprimir en multicolor (AMS) las partes van montadas en una sola
        # impresión: no llevan pivotes, Bambu Studio las imprime juntas.
        return split_by_labels(mesh, labels, palette)

    labels = segment_by_shape(mesh, max_parts=max_parts)
    log(f"  {labels.max() + 1} zonas por forma (uniones cóncavas)")
    parts = split_planar(mesh, labels)
    if connector == "ninguno":
        return parts
    # El espacio se mide sobre las partes sin conectores; las uniones se procesan en
    # el orden de corte (de las puntas hacia dentro) para que cada agujero sepa dónde
    # están los pivotes que ya salen de su parte.
    room = [p.mesh.copy() for p in parts]
    by_label = {p.label: k for k, p in enumerate(parts)}
    pegs_in: dict[int, list[tuple[np.ndarray, float]]] = {}
    loose_parts = []
    for i, part in enumerate(parts):
        plane = getattr(part, "plane", None)
        if plane is None:
            continue
        parent = by_label.get(getattr(part, "parent_label", None))
        if parent is None:
            parent = _parent_of(parts, i, plane[0])
        if parent is None:
            continue
        big, small, loose, note, reach = connect(parts[parent].mesh, part.mesh, plane[0], plane[1],
                                          connector, clearance, room_big=room[parent],
                                          room_small=room[i], keep_out=pegs_in.get(i))
        parts[parent].mesh, part.mesh = big, small
        part.notes.append(note)
        # El pivote entra en `parent` por debajo del plano: su base es zona prohibida
        # para el agujero que el padre recibirá de su propio padre.
        if reach > 0:
            pegs_in.setdefault(parent, []).append((np.asarray(plane[0]), reach))
        if loose is not None:
            loose_parts.append(Part(-1, loose, notes=[f"espiga para la parte {i + 1}"]))
    return parts + loose_parts


def export_parts(parts: list[Part], output_dir, basename: str = "parte") -> dict:
    """Un STL por parte + `ensamblaje.3mf` con todas montadas en su sitio (en Bambu
    Studio / OrcaSlicer se asigna un filamento a cada una) + `partes.json`."""
    import json
    from pathlib import Path

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    scene = trimesh.Scene()
    summary = []
    for i, part in enumerate(parts, start=1):
        tag = "espiga" if part.label == -1 else f"{i:02d}"
        name = f"{basename}_{tag}" if part.label == -1 else f"{basename}_{i:02d}"
        if part.color is not None:
            hex_color = "#" + "".join(f"{int(round(c * 255)):02x}" for c in np.clip(part.color, 0, 1))
            name += f"_{hex_color[1:]}"
            rgba = np.append(np.clip(part.color, 0, 1) * 255, 255).astype(np.uint8)
            part.mesh.visual.face_colors = np.tile(rgba, (len(part.mesh.faces), 1))
        else:
            hex_color = None
        part.mesh.export(out / f"{name}.stl")
        scene.add_geometry(part.mesh, node_name=name, geom_name=name)
        summary.append({
            "archivo": f"{name}.stl",
            "color": hex_color,
            "volumen_cm3": round(float(part.mesh.volume) / 1000, 3),
            "cerrada": bool(part.mesh.is_watertight),
            "cuerpos": part.bodies,
            "notas": part.notes,
        })
    scene.export(out / "ensamblaje.3mf")
    (out / "partes.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    return {"partes": summary, "ensamblaje": str(out / "ensamblaje.3mf")}


def main(argv: list[str] | None = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        prog="scanforge-parts",
        description="Divide una pieza en partes imprimibles que encajan (por forma, por color o con un corte).",
    )
    parser.add_argument("--input", required=True, help="Malla cerrada (STL/OBJ/PLY); para --by color, con textura o colores.")
    parser.add_argument("--output", required=True, help="Carpeta de salida.")
    parser.add_argument("--by", choices=["shape", "color"], default="shape",
                        help="shape: anatomía/uniones (cortes planos); color: zonas de color (default: shape).")
    parser.add_argument("--colors", type=int, default=4, help="Número de colores/filamentos para --by color (default: 4).")
    parser.add_argument("--max-parts", type=int, default=10, help="Máximo de partes para --by shape (default: 10).")
    parser.add_argument("--cut", help='Corte manual por un plano en vez de dividir: "z=40", "x=-5", "y=12".')
    parser.add_argument("--connector", choices=CONNECTORS, default="pivote",
                        help="pivote (hexagonal, no gira), espiga (suelta) o ninguno (default: pivote).")
    parser.add_argument("--color-cloud", help="model.colors.npz de mesh-prep (colores del escaneo para --by color).")
    parser.add_argument("--clearance", type=float, default=CLEARANCE_MM,
                        help=f"Holgura del encaje en mm (default: {CLEARANCE_MM}).")
    args = parser.parse_args(argv)

    mesh = trimesh.load(args.input, force="mesh")
    try:
        if args.cut:
            axis, value = args.cut.replace(" ", "").split("=")
            normal = {"x": (1, 0, 0), "y": (0, 1, 0), "z": (0, 0, 1)}[axis.lower()]
            parts = plane_cut(mesh, normal, float(value), args.connector, args.clearance)
        else:
            colors = ColorCloud.load(args.color_cloud).face_colors(mesh) if args.color_cloud else None
            parts = divide(mesh, args.by, args.colors, args.max_parts, args.connector, args.clearance,
                           colors=colors)
    except (ValueError, KeyError) as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1
    result = export_parts(parts, args.output)
    print(f"{len(result['partes'])} partes en {args.output}:")
    for p in result["partes"]:
        color = f" {p['color']}" if p["color"] else ""
        print(f"  {p['archivo']}{color}  {p['volumen_cm3']} cm³  {'; '.join(p['notas'])}")
    print(f"Ensamblaje: {result['ensamblaje']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
