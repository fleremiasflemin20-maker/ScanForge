"""Pipeline que convierte una reconstrucción fotogramétrica (OBJ/USDZ) o una nube de
puntos (PLY) en una malla lista para imprimir en 3D: limpieza, corte de mesa, base
plana, completado de zonas sin escanear, escala, decimado y reporte de impresión."""

from pathlib import Path

__version__ = "0.2.0"


def _ensure_meshlab_plugins() -> None:
    """En macOS pymeshlab a veces no carga sus filtros (el sistema marca archivos del
    .venv como ocultos y el cargador de plugins de Qt los salta) y entonces `MeshSet`
    no tiene ningún método de filtro. En ese caso cargamos cada plugin a mano y creamos
    los métodos igual que hace pymeshlab."""
    try:
        import pymeshlab
        from pymeshlab import pmeshlab
    except ImportError:
        return
    if pmeshlab.filter_list():
        return
    plugin_dir = Path(pymeshlab.__file__).parent / "PlugIns"
    for lib in sorted(plugin_dir.glob("*filter*")) + sorted(plugin_dir.glob("*io_*")):
        try:
            pmeshlab.load_plugin(str(lib))
        except Exception:
            pass
    for name in pmeshlab.filter_list():
        if not hasattr(pymeshlab.MeshSet, name):
            setattr(pymeshlab.MeshSet, name, pymeshlab.bind_function(name))


_ensure_meshlab_plugins()
