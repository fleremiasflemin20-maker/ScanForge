#!/usr/bin/env python3
"""Receptor Fase 3 para ios-capture: anuncia '_scanforge._tcp' por Bonjour y recibe
sesiones de captura subidas desde el iPhone (ver Sources/Networking/MacUploader.swift
para el protocolo exacto).

Protocolo, por conexión:
  [4 bytes BE: largo del header JSON] [header JSON: {"session": str, "fileCount": int}]
  por cada archivo:
    [4 bytes BE: largo del nombre] [nombre UTF8]
    [8 bytes BE: largo del contenido] [bytes del archivo]

Uso:
  python3 receive_uploads.py --captures-dir ~/ScanForge/captures --port 5050
"""
from __future__ import annotations

import argparse
import json
import re
import socket
import socketserver
import sys
import threading
from datetime import datetime
from pathlib import Path

try:
    from zeroconf import ServiceInfo, Zeroconf
except ImportError:
    ServiceInfo = None
    Zeroconf = None


def read_exact(sock: socket.socket, n: int) -> bytes:
    chunks = []
    remaining = n
    while remaining > 0:
        chunk = sock.recv(min(remaining, 65536))
        if not chunk:
            raise ConnectionError("Conexión cerrada antes de recibir todos los datos esperados.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def safe_filename(name: str) -> str:
    name = Path(name).name  # descarta cualquier componente de ruta
    return re.sub(r"[^A-Za-z0-9._-]", "_", name) or "archivo"


def safe_session_dirname(session_name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "-", session_name.strip()) or "objeto"
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    return f"{cleaned}-{timestamp}"


class UploadHandler(socketserver.BaseRequestHandler):
    captures_dir: Path = Path(".")
    on_session_received = None  # callable(Path) opcional

    def handle(self) -> None:
        sock = self.request
        try:
            header_len = int.from_bytes(read_exact(sock, 4), "big")
            header = json.loads(read_exact(sock, header_len))
            session_name = str(header.get("session", "objeto"))
            file_count = int(header.get("fileCount", 0))
        except Exception as e:
            print(f"[recv] Header inválido de {self.client_address}: {e}", file=sys.stderr)
            return

        session_dir = self.captures_dir / safe_session_dirname(session_name)
        session_dir.mkdir(parents=True, exist_ok=True)
        print(f"[recv] Sesión '{session_name}' de {self.client_address}: {file_count} archivos -> {session_dir}")

        received = 0
        try:
            for _ in range(file_count):
                name_len = int.from_bytes(read_exact(sock, 4), "big")
                name = read_exact(sock, name_len).decode("utf-8")
                size = int.from_bytes(read_exact(sock, 8), "big")
                data = read_exact(sock, size)

                out_path = session_dir / safe_filename(name)
                out_path.write_bytes(data)
                received += 1
                print(f"[recv]   {received}/{file_count}: {out_path.name} ({len(data)} bytes)")
        except Exception as e:
            print(f"[recv] Subida incompleta ({received}/{file_count}): {e}", file=sys.stderr)
            return

        print(f"[recv] Sesión completa: {session_dir} ({received} archivos)")
        if UploadHandler.on_session_received:
            UploadHandler.on_session_received(session_dir)


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


def advertise_bonjour(port: int) -> "Zeroconf | None":
    if Zeroconf is None:
        print("[recv] Aviso: el paquete 'zeroconf' no está instalado (pip install zeroconf); "
              "el servidor funciona pero el iPhone no podrá descubrirlo automáticamente.", file=sys.stderr)
        return None

    zeroconf = Zeroconf()
    hostname = socket.gethostname().split(".")[0]
    local_ip = socket.gethostbyname(socket.gethostname())
    info = ServiceInfo(
        "_scanforge._tcp.local.",
        f"{hostname}._scanforge._tcp.local.",
        addresses=[socket.inet_aton(local_ip)],
        port=port,
        properties={},
    )
    zeroconf.register_service(info)
    print(f"[recv] Anunciado como _scanforge._tcp en {local_ip}:{port}")
    return zeroconf


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures-dir", default="./captures", help="Carpeta donde guardar las sesiones recibidas.")
    parser.add_argument("--port", type=int, default=5050)
    args = parser.parse_args()

    captures_dir = Path(args.captures_dir).expanduser()
    captures_dir.mkdir(parents=True, exist_ok=True)

    UploadHandler.captures_dir = captures_dir

    server = ReusableTCPServer(("0.0.0.0", args.port), UploadHandler)
    zeroconf = advertise_bonjour(args.port)

    print(f"[recv] Escuchando en el puerto {args.port}, guardando en {captures_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        if zeroconf:
            zeroconf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
