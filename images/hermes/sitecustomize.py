"""OpenShell Landlock allows /dev/pts/ptmx but denies /dev/ptmx by path.

CPython ``os.openpty()`` / ``pty.openpty()`` open ``/dev/ptmx``, which fails
inside the sandbox with EACCES and surfaces as ``OSError: out of pty devices``
(Hermes dashboard Chat tab). Route PTY allocation through ``/dev/pts/ptmx``.

Installed at ``/usr/local/lib/hermes/pythonpath/sitecustomize.py`` and copied into
the Hermes venv ``site-packages`` (auto-import). Units also put the pythonpath
dir on ``PYTHONPATH``.
"""
from __future__ import annotations

import fcntl
import os
import struct

_TIOCSPTLCK = 0x40045431


def _openpty():
    master = os.open("/dev/pts/ptmx", os.O_RDWR | os.O_NOCTTY)
    fcntl.ioctl(master, _TIOCSPTLCK, struct.pack("i", 0))
    slave = os.open(os.ptsname(master), os.O_RDWR | os.O_NOCTTY)
    return master, slave


os.openpty = _openpty
try:
    import pty

    pty.openpty = _openpty
except Exception:
    pass
