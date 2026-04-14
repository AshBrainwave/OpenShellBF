#!/usr/bin/env python3
"""
Render the OpenShellBF target architecture as both SVG and PNG without
third-party Python packages.

The PNG path uses:
- custom vector/raster drawing
- system TTF fonts through libfreetype via ctypes
- a minimal PNG encoder built from the standard library
"""

from __future__ import annotations

import ctypes
import ctypes.util
import math
import os
import struct
import textwrap
import zlib
from dataclasses import dataclass
from xml.sax.saxutils import escape


WIDTH = 1800
HEIGHT = 1180

BG = "#f7f3eb"
INK = "#17212b"
SUBTLE = "#62717f"
CONTROL = "#0b7285"
DATA = "#bc6c25"
DANGER = "#b02a37"
HOST = "#6c757d"
OPENSHELL = "#2a9d8f"
SANDBOX = "#457b9d"
DPU = "#f4a261"
LANE = "#e9c46a"
WHITE = "#ffffff"


@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int
    fill: str
    stroke: str
    radius: int = 20
    stroke_width: int = 3


@dataclass
class Box:
    rect: Rect
    title: str
    lines: list[str]
    fill_title: str | None = None
    title_color: str = WHITE
    text_color: str = INK
    title_size: int = 22
    text_size: int = 16


@dataclass
class Arrow:
    x1: int
    y1: int
    x2: int
    y2: int
    color: str
    width: int
    label: str = ""
    label_x: int | None = None
    label_y: int | None = None
    dashed: bool = False
    label_fill: str = "#fff8ee"


def hex_to_rgb(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))


class RasterCanvas:
    def __init__(self, width: int, height: int, bg: str):
        self.width = width
        self.height = height
        r, g, b = hex_to_rgb(bg)
        self.buf = bytearray([r, g, b, 255] * (width * height))

    def _blend(self, x: int, y: int, color: str, alpha: int = 255) -> None:
        if x < 0 or y < 0 or x >= self.width or y >= self.height or alpha <= 0:
            return
        idx = (y * self.width + x) * 4
        sr, sg, sb = hex_to_rgb(color)
        sa = alpha / 255.0
        dr, dg, db, da = self.buf[idx : idx + 4]
        out_r = int(sr * sa + dr * (1.0 - sa))
        out_g = int(sg * sa + dg * (1.0 - sa))
        out_b = int(sb * sa + db * (1.0 - sa))
        self.buf[idx : idx + 4] = bytes((out_r, out_g, out_b, 255))

    def fill_rect(self, x: int, y: int, w: int, h: int, color: str) -> None:
        for yy in range(max(0, y), min(self.height, y + h)):
            row = yy * self.width
            for xx in range(max(0, x), min(self.width, x + w)):
                idx = (row + xx) * 4
                self.buf[idx : idx + 4] = bytes((*hex_to_rgb(color), 255))

    def fill_round_rect(self, x: int, y: int, w: int, h: int, radius: int, color: str) -> None:
        for yy in range(y, y + h):
            if yy < 0 or yy >= self.height:
                continue
            for xx in range(x, x + w):
                if xx < 0 or xx >= self.width:
                    continue
                inside = True
                if xx < x + radius and yy < y + radius:
                    inside = (xx - (x + radius)) ** 2 + (yy - (y + radius)) ** 2 <= radius**2
                elif xx >= x + w - radius and yy < y + radius:
                    inside = (xx - (x + w - radius - 1)) ** 2 + (yy - (y + radius)) ** 2 <= radius**2
                elif xx < x + radius and yy >= y + h - radius:
                    inside = (xx - (x + radius)) ** 2 + (yy - (y + h - radius - 1)) ** 2 <= radius**2
                elif xx >= x + w - radius and yy >= y + h - radius:
                    inside = (xx - (x + w - radius - 1)) ** 2 + (yy - (y + h - radius - 1)) ** 2 <= radius**2
                if inside:
                    idx = (yy * self.width + xx) * 4
                    self.buf[idx : idx + 4] = bytes((*hex_to_rgb(color), 255))

    def line(self, x1: int, y1: int, x2: int, y2: int, color: str, width: int = 1, dashed: bool = False) -> None:
        dx = x2 - x1
        dy = y2 - y1
        length = max(abs(dx), abs(dy), 1)
        dash_on = 18
        dash_off = 12
        for step in range(length + 1):
            if dashed and step % (dash_on + dash_off) >= dash_on:
                continue
            t = step / length
            x = int(round(x1 + dx * t))
            y = int(round(y1 + dy * t))
            for oy in range(-width // 2, width // 2 + 1):
                for ox in range(-width // 2, width // 2 + 1):
                    self._blend(x + ox, y + oy, color, 255)

    def fill_triangle(self, p1: tuple[int, int], p2: tuple[int, int], p3: tuple[int, int], color: str) -> None:
        min_x = max(0, min(p1[0], p2[0], p3[0]))
        max_x = min(self.width - 1, max(p1[0], p2[0], p3[0]))
        min_y = max(0, min(p1[1], p2[1], p3[1]))
        max_y = min(self.height - 1, max(p1[1], p2[1], p3[1]))

        def area(a: tuple[int, int], b: tuple[int, int], c: tuple[int, int]) -> int:
            return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

        total = area(p1, p2, p3)
        if total == 0:
            return

        for y in range(min_y, max_y + 1):
            for x in range(min_x, max_x + 1):
                w1 = area((x, y), p2, p3)
                w2 = area(p1, (x, y), p3)
                w3 = area(p1, p2, (x, y))
                if (w1 >= 0 and w2 >= 0 and w3 >= 0 and total > 0) or (
                    w1 <= 0 and w2 <= 0 and w3 <= 0 and total < 0
                ):
                    self._blend(x, y, color, 255)

    def arrow(self, arrow: Arrow) -> None:
        self.line(arrow.x1, arrow.y1, arrow.x2, arrow.y2, arrow.color, arrow.width, arrow.dashed)
        angle = math.atan2(arrow.y2 - arrow.y1, arrow.x2 - arrow.x1)
        head_len = 16 + arrow.width * 2
        wing = 9 + arrow.width
        tip = (arrow.x2, arrow.y2)
        p2 = (
            int(arrow.x2 - head_len * math.cos(angle) + wing * math.sin(angle)),
            int(arrow.y2 - head_len * math.sin(angle) - wing * math.cos(angle)),
        )
        p3 = (
            int(arrow.x2 - head_len * math.cos(angle) - wing * math.sin(angle)),
            int(arrow.y2 - head_len * math.sin(angle) + wing * math.cos(angle)),
        )
        self.fill_triangle(tip, p2, p3, arrow.color)

    def save_png(self, path: str) -> None:
        raw = bytearray()
        row_bytes = self.width * 4
        for y in range(self.height):
            raw.append(0)
            start = y * row_bytes
            raw.extend(self.buf[start : start + row_bytes])

        def chunk(tag: bytes, data: bytes) -> bytes:
            return struct.pack("!I", len(data)) + tag + data + struct.pack(
                "!I", zlib.crc32(tag + data) & 0xFFFFFFFF
            )

        ihdr = struct.pack("!IIBBBBB", self.width, self.height, 8, 6, 0, 0, 0)
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
        with open(path, "wb") as f:
            f.write(png)


class FT_BBox(ctypes.Structure):
    _fields_ = [("xMin", ctypes.c_long), ("yMin", ctypes.c_long), ("xMax", ctypes.c_long), ("yMax", ctypes.c_long)]


class FT_Generic(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("finalizer", ctypes.c_void_p)]


class FT_Glyph_Metrics(ctypes.Structure):
    _fields_ = [
        ("width", ctypes.c_long),
        ("height", ctypes.c_long),
        ("horiBearingX", ctypes.c_long),
        ("horiBearingY", ctypes.c_long),
        ("horiAdvance", ctypes.c_long),
        ("vertBearingX", ctypes.c_long),
        ("vertBearingY", ctypes.c_long),
        ("vertAdvance", ctypes.c_long),
    ]


class FT_Vector(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class FT_Bitmap(ctypes.Structure):
    _fields_ = [
        ("rows", ctypes.c_uint),
        ("width", ctypes.c_uint),
        ("pitch", ctypes.c_int),
        ("buffer", ctypes.POINTER(ctypes.c_ubyte)),
        ("num_grays", ctypes.c_ushort),
        ("pixel_mode", ctypes.c_ubyte),
        ("palette_mode", ctypes.c_ubyte),
        ("palette", ctypes.c_void_p),
    ]


class FT_GlyphSlotRec(ctypes.Structure):
    pass


FT_GlyphSlotRec._fields_ = [
    ("library", ctypes.c_void_p),
    ("face", ctypes.c_void_p),
    ("next", ctypes.c_void_p),
    ("reserved", ctypes.c_uint),
    ("generic", FT_Generic),
    ("metrics", FT_Glyph_Metrics),
    ("linearHoriAdvance", ctypes.c_long),
    ("linearVertAdvance", ctypes.c_long),
    ("advance", FT_Vector),
    ("format", ctypes.c_uint),
    ("bitmap", FT_Bitmap),
    ("bitmap_left", ctypes.c_int),
    ("bitmap_top", ctypes.c_int),
]


class FT_FaceRec(ctypes.Structure):
    _fields_ = [
        ("num_faces", ctypes.c_long),
        ("face_index", ctypes.c_long),
        ("face_flags", ctypes.c_long),
        ("style_flags", ctypes.c_long),
        ("num_glyphs", ctypes.c_long),
        ("family_name", ctypes.c_char_p),
        ("style_name", ctypes.c_char_p),
        ("num_fixed_sizes", ctypes.c_int),
        ("available_sizes", ctypes.c_void_p),
        ("num_charmaps", ctypes.c_int),
        ("charmaps", ctypes.c_void_p),
        ("generic", FT_Generic),
        ("bbox", FT_BBox),
        ("units_per_EM", ctypes.c_ushort),
        ("ascender", ctypes.c_short),
        ("descender", ctypes.c_short),
        ("height", ctypes.c_short),
        ("max_advance_width", ctypes.c_short),
        ("max_advance_height", ctypes.c_short),
        ("underline_position", ctypes.c_short),
        ("underline_thickness", ctypes.c_short),
        ("glyph", ctypes.POINTER(FT_GlyphSlotRec)),
        ("size", ctypes.c_void_p),
        ("charmap", ctypes.c_void_p),
    ]


class FreeTypeRenderer:
    FT_LOAD_RENDER = 0x4

    def __init__(self) -> None:
        lib_name = ctypes.util.find_library("freetype")
        if not lib_name:
            raise RuntimeError("libfreetype not found")
        self.ft = ctypes.CDLL(lib_name)
        self.lib = ctypes.c_void_p()
        if self.ft.FT_Init_FreeType(ctypes.byref(self.lib)) != 0:
            raise RuntimeError("FT_Init_FreeType failed")

        self.ft.FT_New_Face.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.POINTER(ctypes.c_void_p)]
        self.ft.FT_Set_Pixel_Sizes.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
        self.ft.FT_Load_Char.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]

        self.faces: dict[tuple[str, bool], ctypes.c_void_p] = {}
        self.default_font = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        self.bold_font = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

    def _face(self, bold: bool) -> ctypes.c_void_p:
        path = self.bold_font if bold else self.default_font
        key = (path, bold)
        if key not in self.faces:
            face = ctypes.c_void_p()
            err = self.ft.FT_New_Face(self.lib, path.encode(), 0, ctypes.byref(face))
            if err != 0:
                raise RuntimeError(f"FT_New_Face failed for {path}")
            self.faces[key] = face
        return self.faces[key]

    def text_width(self, text: str, size: int, bold: bool = False) -> int:
        face = self._face(bold)
        self.ft.FT_Set_Pixel_Sizes(face, 0, size)
        width = 0
        for ch in text:
            if self.ft.FT_Load_Char(face, ord(ch), self.FT_LOAD_RENDER) != 0:
                continue
            slot = ctypes.cast(ctypes.cast(face, ctypes.POINTER(FT_FaceRec)).contents.glyph, ctypes.POINTER(FT_GlyphSlotRec)).contents
            width += slot.advance.x >> 6
        return width

    def draw_text(
        self,
        canvas: RasterCanvas,
        text: str,
        x: int,
        y: int,
        size: int,
        color: str,
        bold: bool = False,
    ) -> None:
        face = self._face(bold)
        self.ft.FT_Set_Pixel_Sizes(face, 0, size)
        pen_x = x
        baseline = y
        for ch in text:
            if self.ft.FT_Load_Char(face, ord(ch), self.FT_LOAD_RENDER) != 0:
                continue
            face_rec = ctypes.cast(face, ctypes.POINTER(FT_FaceRec)).contents
            slot = face_rec.glyph.contents
            bitmap = slot.bitmap
            pitch = abs(bitmap.pitch)
            rows = bitmap.rows
            cols = bitmap.width
            buffer = ctypes.cast(bitmap.buffer, ctypes.POINTER(ctypes.c_ubyte * (pitch * rows))).contents if bitmap.buffer else None
            top = slot.bitmap_top
            left = slot.bitmap_left
            if buffer:
                for row in range(rows):
                    for col in range(cols):
                        alpha = buffer[row * pitch + col]
                        if alpha:
                            canvas._blend(pen_x + left + col, baseline - top + row, color, alpha)
            pen_x += slot.advance.x >> 6

    def close(self) -> None:
        for face in self.faces.values():
            self.ft.FT_Done_Face(face)
        if self.lib:
            self.ft.FT_Done_FreeType(self.lib)


def draw_box(canvas: RasterCanvas, font: FreeTypeRenderer, box: Box) -> None:
    r = box.rect
    canvas.fill_round_rect(r.x, r.y, r.w, r.h, r.radius, r.fill)
    for offset in range(r.stroke_width):
        canvas.line(r.x + r.radius, r.y + offset, r.x + r.w - r.radius, r.y + offset, r.stroke, 1)
        canvas.line(r.x + r.radius, r.y + r.h - 1 - offset, r.x + r.w - r.radius, r.y + r.h - 1 - offset, r.stroke, 1)
        canvas.line(r.x + offset, r.y + r.radius, r.x + offset, r.y + r.h - r.radius, r.stroke, 1)
        canvas.line(r.x + r.w - 1 - offset, r.y + r.radius, r.x + r.w - 1 - offset, r.y + r.h - r.radius, r.stroke, 1)

    title_fill = box.fill_title or r.stroke
    title_h = 38 if not box.lines else 42
    canvas.fill_round_rect(r.x + 8, r.y + 8, r.w - 16, title_h, min(16, r.radius), title_fill)

    title_w = font.text_width(box.title, box.title_size, bold=True)
    font.draw_text(canvas, box.title, r.x + (r.w - title_w) // 2, r.y + 36, box.title_size, box.title_color, bold=True)

    y = r.y + 68
    for line in box.lines:
        line_w = font.text_width(line, box.text_size, bold=False)
        font.draw_text(canvas, line, r.x + (r.w - line_w) // 2, y + box.text_size, box.text_size, box.text_color, bold=False)
        y += box.text_size + 10


def draw_label(canvas: RasterCanvas, font: FreeTypeRenderer, text: str, x: int, y: int, fill: str = "#fff8ee", color: str = INK) -> None:
    lines = text.split("\n")
    widths = [font.text_width(line, 15, bold=True) for line in lines]
    w = max(widths) + 24
    h = len(lines) * 24 + 12
    canvas.fill_round_rect(x, y, w, h, 12, fill)
    for i, line in enumerate(lines):
        font.draw_text(canvas, line, x + (w - widths[i]) // 2, y + 24 + i * 24, 15, color, bold=True)


def draw_arrow_with_label(canvas: RasterCanvas, font: FreeTypeRenderer, arrow: Arrow) -> None:
    canvas.arrow(arrow)
    if arrow.label and arrow.label_x is not None and arrow.label_y is not None:
        draw_label(canvas, font, arrow.label, arrow.label_x, arrow.label_y, arrow.label_fill, arrow.color)


def svg_rect(rect: Rect) -> str:
    return (
        f'<rect x="{rect.x}" y="{rect.y}" width="{rect.w}" height="{rect.h}" '
        f'rx="{rect.radius}" ry="{rect.radius}" fill="{rect.fill}" '
        f'stroke="{rect.stroke}" stroke-width="{rect.stroke_width}" />'
    )


def svg_box(box: Box) -> str:
    title_h = 42
    items = [svg_rect(box.rect)]
    items.append(
        f'<rect x="{box.rect.x + 8}" y="{box.rect.y + 8}" width="{box.rect.w - 16}" height="{title_h}" '
        f'rx="14" ry="14" fill="{box.fill_title or box.rect.stroke}" />'
    )
    items.append(
        f'<text x="{box.rect.x + box.rect.w / 2}" y="{box.rect.y + 35}" '
        f'font-family="DejaVu Sans" font-size="{box.title_size}" font-weight="700" '
        f'text-anchor="middle" fill="{box.title_color}">{escape(box.title)}</text>'
    )
    y = box.rect.y + 90
    for line in box.lines:
        items.append(
            f'<text x="{box.rect.x + box.rect.w / 2}" y="{y}" '
            f'font-family="DejaVu Sans" font-size="{box.text_size}" '
            f'text-anchor="middle" fill="{box.text_color}">{escape(line)}</text>'
        )
        y += box.text_size + 12
    return "\n".join(items)


def svg_arrow(arrow: Arrow, marker_id: str) -> str:
    dash = ' stroke-dasharray="12 10"' if arrow.dashed else ""
    parts = [
        f'<line x1="{arrow.x1}" y1="{arrow.y1}" x2="{arrow.x2}" y2="{arrow.y2}" '
        f'stroke="{arrow.color}" stroke-width="{arrow.width}"{dash} marker-end="url(#{marker_id})" />'
    ]
    if arrow.label and arrow.label_x is not None and arrow.label_y is not None:
        lines = arrow.label.split("\n")
        width = max(len(line) for line in lines) * 9 + 24
        height = len(lines) * 22 + 10
        parts.append(
            f'<rect x="{arrow.label_x}" y="{arrow.label_y}" width="{width}" height="{height}" rx="12" ry="12" '
            f'fill="{arrow.label_fill}" stroke="none" />'
        )
        for idx, line in enumerate(lines):
            parts.append(
                f'<text x="{arrow.label_x + width / 2}" y="{arrow.label_y + 23 + idx * 22}" '
                f'font-family="DejaVu Sans" font-size="15" font-weight="700" '
                f'text-anchor="middle" fill="{arrow.color}">{escape(line)}</text>'
            )
    return "\n".join(parts)


def build_model() -> tuple[list[Box], list[Arrow], list[str]]:
    boxes: list[Box] = []
    arrows: list[Arrow] = []
    free_text: list[str] = []

    boxes.append(
        Box(
            Rect(60, 90, 360, 120, "#e7f7f4", OPENSHELL),
            "OPENSHELL SERVER",
            ["POLICY BUNDLES", "CREDENTIAL SOURCES", "AUDIT SOURCE OF TRUTH"],
            fill_title=OPENSHELL,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(820, 140, 920, 950, "#fff7ed", DPU, radius=28, stroke_width=4),
            "BLUEFIELD 3 DPU",
            [],
            fill_title=DPU,
            title_color=INK,
            title_size=28,
            text_size=18,
        )
    )

    boxes.append(
        Box(
            Rect(1030, 205, 310, 120, "#e9f6f8", CONTROL),
            "DPU CONTROL AGENT",
            ["MTLS PULL", "SANDBOX BINDINGS", "POLICY CACHE"],
            fill_title=CONTROL,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(1410, 100, 260, 120, "#ecfdf3", "#6a994e"),
            "INTERNET",
            ["UPSTREAM APIS", "MODEL ENDPOINTS", "EXTERNAL EGRESS"],
            fill_title="#6a994e",
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(60, 260, 320, 830, "#f1f3f5", HOST, radius=26, stroke_width=4),
            "HOST",
            ["UNTRUSTED CONTROL DOMAIN"],
            fill_title=HOST,
            title_color=WHITE,
            title_size=26,
        )
    )

    boxes.append(
        Box(
            Rect(95, 375, 250, 120, "#ffffff", HOST),
            "HOST ORCHESTRATOR",
            ["CREATE START STOP ONLY", "NO POLICY OWNERSHIP"],
            fill_title=HOST,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(95, 535, 250, 120, "#fff4f4", DANGER),
            "NO HOST TO DPU APPS",
            ["NO DPU POLICY PUSH", "NO DPU SECRETS"],
            fill_title=DANGER,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(430, 260, 330, 830, "#edf6fb", SANDBOX, radius=26, stroke_width=4),
            "PROTECTED SANDBOXES",
            ["ONE DEDICATED VF PER SANDBOX"],
            fill_title=SANDBOX,
            title_color=WHITE,
            title_size=26,
        )
    )

    boxes.append(
        Box(
            Rect(465, 375, 260, 180, "#ffffff", SANDBOX),
            "SANDBOX VM SB1",
            ["ETH0 MGMT", "ETH1 PROTECTED", "POLICY CONTEXT = SB1"],
            fill_title=SANDBOX,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(465, 620, 260, 180, "#ffffff", SANDBOX),
            "SANDBOX VM SB2",
            ["ETH0 MGMT", "ETH1 PROTECTED", "POLICY CONTEXT = SB2"],
            fill_title=SANDBOX,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(470, 860, 120, 90, "#ffe8cc", DATA),
            "VF A",
            ["SB1"],
            fill_title=DATA,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(605, 860, 120, 90, "#ffe8cc", DATA),
            "VF B",
            ["SB2"],
            fill_title=DATA,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(910, 405, 250, 130, "#ffffff", DPU),
            "PROTECTED INGRESS",
            ["VF TO SANDBOX MAP", "DIRECT OR MANAGED_PROXY", "FAIL CLOSED DEFAULT"],
            fill_title=DPU,
            title_color=INK,
        )
    )

    boxes.append(
        Box(
            Rect(1220, 405, 260, 130, "#fffaf0", CONTROL),
            "POLICY CACHE",
            ["OPA DATA", "ROUTE MODE", "CREDENTIAL REFS"],
            fill_title=CONTROL,
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(910, 590, 570, 320, "#fff8e1", LANE),
            "MANAGED_PROXY LANE",
            ["PER SANDBOX PROXY ISOLATION"],
            fill_title=LANE,
            title_color=INK,
            title_size=24,
        )
    )

    boxes.append(
        Box(
            Rect(955, 680, 220, 130, "#ffffff", "#8d5524"),
            "PROXY SB1",
            ["CONTAINER NOW", "DPU VM LATER", "POLICY = SB1"],
            fill_title="#8d5524",
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(1215, 680, 220, 130, "#ffffff", "#8d5524"),
            "PROXY SB2",
            ["CONTAINER NOW", "DPU VM LATER", "POLICY = SB2"],
            fill_title="#8d5524",
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(1510, 590, 180, 320, "#eef6ff", "#3d5a80"),
            "DIRECT LANE",
            ["SHARED", "DOCA FLOW", "DIRECT EGRESS"],
            fill_title="#3d5a80",
            title_color=WHITE,
        )
    )

    boxes.append(
        Box(
            Rect(1180, 950, 250, 110, "#ecfdf3", "#6a994e"),
            "UPLINK PF OR SF",
            ["DPU OWNED EGRESS", "NO HOST CONTROL PATH"],
            fill_title="#6a994e",
            title_color=WHITE,
        )
    )

    arrows.extend(
        [
            Arrow(420, 120, 1000, 120, CONTROL, 5, "DPU OWNED CONTROL PLANE\nMTLS PULL", 610, 88, dashed=True, label_fill="#e8fbff"),
            Arrow(1000, 120, 1030, 265, CONTROL, 5, dashed=True),
            Arrow(1185, 325, 1300, 405, CONTROL, 4, "PUBLISH LOCAL POLICY", 1185, 350, dashed=True, label_fill="#e8fbff"),
            Arrow(345, 435, 465, 435, HOST, 4, "CREATE AND BOOT", 350, 392, dashed=True, label_fill="#f5f7fa"),
            Arrow(345, 680, 465, 680, HOST, 4, dashed=True),
            Arrow(595, 555, 530, 860, DATA, 5),
            Arrow(595, 800, 665, 860, DATA, 5),
            Arrow(590, 905, 910, 470, DATA, 6),
            Arrow(665, 905, 910, 470, DATA, 6),
            Arrow(1160, 470, 1065, 680, DATA, 5),
            Arrow(1160, 470, 1325, 680, DATA, 5),
            Arrow(1160, 470, 1510, 735, DATA, 5),
            Arrow(1070, 810, 1285, 950, DATA, 5),
            Arrow(1325, 810, 1310, 950, DATA, 5),
            Arrow(1600, 910, 1410, 1005, DATA, 5),
            Arrow(1430, 1000, 1540, 220, DATA, 6, "OUTBOUND INTERNET EGRESS", 1455, 600, label_fill="#fff4e6"),
        ]
    )

    free_text.append(
        '<text x="900" y="40" font-family="DejaVu Sans" font-size="38" font-weight="700" '
        f'text-anchor="middle" fill="{INK}">OpenShell BF3 Target Architecture</text>'
    )
    free_text.append(
        '<text x="900" y="74" font-family="DejaVu Sans" font-size="20" '
        f'text-anchor="middle" fill="{SUBTLE}">Per-sandbox VF isolation, per-sandbox DPU proxy containers, and a DPU-owned control plane</text>'
    )
    free_text.append(
        '<text x="900" y="1140" font-family="DejaVu Sans" font-size="18" '
        f'text-anchor="middle" fill="{SUBTLE}">Policy is always per sandbox. Containers are the first isolation unit on the DPU; DPU VMs are a later hardening step.</text>'
    )
    return boxes, arrows, free_text


def render_png(out_path: str) -> None:
    canvas = RasterCanvas(WIDTH, HEIGHT, BG)
    font = FreeTypeRenderer()
    try:
        boxes, arrows, _ = build_model()
        title = "OpenShell BF3 Target Architecture"
        subtitle = "Per-sandbox VF isolation, per-sandbox DPU proxy containers, and a DPU-owned control plane"
        footer = "Policy is always per sandbox. Containers are the first isolation unit on the DPU; DPU VMs are a later hardening step."

        title_w = font.text_width(title, 38, bold=True)
        font.draw_text(canvas, title, (WIDTH - title_w) // 2, 42, 38, INK, bold=True)
        subtitle_w = font.text_width(subtitle, 20, bold=False)
        font.draw_text(canvas, subtitle, (WIDTH - subtitle_w) // 2, 76, 20, SUBTLE, bold=False)

        for box in boxes:
            draw_box(canvas, font, box)
        for arrow in arrows:
            draw_arrow_with_label(canvas, font, arrow)

        footer_w = font.text_width(footer, 18, bold=False)
        font.draw_text(canvas, footer, (WIDTH - footer_w) // 2, 1144, 18, SUBTLE, bold=False)
        canvas.save_png(out_path)
    finally:
        font.close()


def render_svg(out_path: str) -> None:
    boxes, arrows, free_text = build_model()
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">',
        f'<rect x="0" y="0" width="{WIDTH}" height="{HEIGHT}" fill="{BG}" />',
        '<defs>',
        f'<marker id="arrow-control" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{CONTROL}" /></marker>',
        f'<marker id="arrow-data" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{DATA}" /></marker>',
        f'<marker id="arrow-host" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{HOST}" /></marker>',
        "</defs>",
    ]
    parts.extend(free_text)
    for box in boxes:
        parts.append(svg_box(box))
    for arrow in arrows:
        marker = "arrow-control" if arrow.color == CONTROL else "arrow-host" if arrow.color == HOST else "arrow-data"
        parts.append(svg_arrow(arrow, marker))
    parts.append("</svg>")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))


def main() -> int:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    png_path = os.path.join(script_dir, "vf-isolated-dpu-architecture.png")
    svg_path = os.path.join(script_dir, "vf-isolated-dpu-architecture.svg")
    render_svg(svg_path)
    render_png(png_path)
    print(f"Wrote {svg_path}")
    print(f"Wrote {png_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
