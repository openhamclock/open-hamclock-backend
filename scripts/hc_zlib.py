#!/usr/bin/env python3

# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
hc_zlib.py

Shared helpers for HamClock-style .z files (zlib-compressed payloads).
"""

from __future__ import annotations
import zlib


def zread(path: str) -> bytes:
    data = open(path, "rb").read()
    return zlib.decompress(data) if path.endswith(".z") else data


def zwrite(path: str, blob: bytes, level: int = 9):
    with open(path, "wb") as f:
        f.write(zlib.compress(blob, level))


def zcompress_file(in_path: str, out_path: str, level: int = 9):
    data = open(in_path, "rb").read()
    zwrite(out_path, data, level=level)
