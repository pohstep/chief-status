#!/usr/bin/env python3
"""Render docs/demo.gif, docs/panel.png, docs/hero.png and docs/icon.png.

Since v1.4.0, docs/panel.png is the app's own `ChiefStatus --render-preview` panel-light.png,
and docs/hero.png places that panel on this script's background. Re-running this script
draws the older v1.3 faces, so keep it to demo.gif and icon.png.

The panel shows one fresh working card and one maybe-stale card (black, 404 face).

This is a faithful port of the menu-bar drawing and motion in
menubar/Sources/Icon.swift (StatusIcon.paint, fitScale, FaceMotion).
The Mac app is not compiled here. Geometry stays in the same 18pt space
and is only scaled up so the GIF is crisp at 2x.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DOCS = Path(__file__).resolve().parent

ORANGE = (243, 156, 40, 255)
EYE = (26, 20, 16, 255)
GREY = (142, 142, 147, 255)
EYE_GREY = (40, 40, 42, 255)
RED = (229, 72, 77, 255)
EYE_RED = (42, 16, 18, 255)
DONE = (52, 199, 89, 255)

POINT = 18
# Device pixels per menu-bar point. 2x of a 4x enlargement, so the cube
# reads in the README and stays sharp on a retina screen.
PIXELS_PER_PT = 8
SUPERSAMPLE = 4


def smoothstep(value: float) -> float:
    t = min(1.0, max(0.0, value))
    return t * t * (3 - 2 * t)


def unit(time: float, start: float, duration: float) -> float:
    if duration <= 0:
        return 1.0
    return min(1.0, max(0.0, (time - start) / duration))


def orange_pose(time: float, move: str | None, move_start: float, move_duration: float) -> dict:
    phase = time * (2 * math.pi) / 1.6
    wave = math.sin(phase)
    pose = {
        "bob": wave * 0.9,
        "squash_x": 1 - 0.035 * wave,
        "squash_y": 1 + 0.035 * wave,
        "rotation": 0.0,
        "eye_shift": 0.0,
        "eye_open": 1.0,
        "shake": 0.0,
    }
    if move is None:
        return pose
    progress = unit(time, move_start, move_duration)
    env = math.sin(math.pi * progress)
    pose["bob"] *= 1 - env
    pose["squash_x"] = pose["squash_x"] * (1 - env) + env
    pose["squash_y"] = pose["squash_y"] * (1 - env) + env
    if move == "twirl":
        pose["rotation"] = smoothstep(progress) * 2 * math.pi
    elif move == "hop":
        pose["bob"] += math.sin(math.pi * progress) * 0.7
        land = max(0.0, (progress - 0.62) / 0.38)
        land_env = math.sin(math.pi * min(1.0, land))
        pose["squash_y"] = 1 - 0.12 * land_env
        pose["squash_x"] = 1 + 0.10 * land_env
    elif move == "wiggle":
        pose["rotation"] = math.sin(progress * 3 * 2 * math.pi) * env * (7 * math.pi / 180)
    elif move == "look":
        pose["eye_shift"] = math.sin(progress * 2 * 2 * math.pi) * env * 1.0
    elif move == "blink":
        pose["eye_open"] = 1 - 0.82 * env
    return pose


def grey_pose(time: float, blink_on: bool, blink_start: float, blink_duration: float) -> dict:
    pose = {
        "bob": 0.0,
        "squash_x": 1.0,
        "squash_y": 1.0,
        "rotation": 0.0,
        "eye_shift": 0.0,
        "eye_open": 1.0,
        "shake": 0.0,
    }
    if blink_on:
        progress = unit(time, blink_start, blink_duration)
        pose["eye_open"] = 1 - 0.82 * math.sin(math.pi * progress)
    return pose


def red_pose(time: float, shake_on: bool, shake_start: float) -> dict:
    pose = {
        "bob": 0.0,
        "squash_x": 1.0,
        "squash_y": 1.0,
        "rotation": 0.0,
        "eye_shift": 0.0,
        "eye_open": 1.0,
        "shake": 0.0,
    }
    if shake_on:
        progress = unit(time, shake_start, 0.4)
        pose["shake"] = math.sin(progress * 3 * 2 * math.pi) * (1 - progress) * 0.6
    return pose


def fit_scale(pose: dict, centre_x: float, centre_y: float) -> float:
    half_x = 8 * abs(pose["squash_x"])
    half_y = 8 * abs(pose["squash_y"])
    cosine = abs(math.cos(pose["rotation"]))
    sine = abs(math.sin(pose["rotation"]))
    half_w = cosine * half_x + sine * half_y
    half_h = sine * half_x + cosine * half_y
    if half_w <= 0.001 or half_h <= 0.001:
        return 1.0
    cx = centre_x + pose["shake"]
    cy = centre_y
    room_x = min(cx, POINT - cx)
    room_y = min(cy, POINT - cy)
    if room_x <= 0 or room_y <= 0:
        return 1.0
    return min(1.0, room_x / half_w, room_y / half_h)


def in_round_rect(x, y, rx, ry, rw, rh, radius):
    inside = (x >= rx) & (x <= rx + rw) & (y >= ry) & (y <= ry + rh)
    cx = np.clip(x, rx + radius, rx + rw - radius)
    cy = np.clip(y, ry + radius, ry + rh - radius)
    in_cross = ((x >= rx + radius) & (x <= rx + rw - radius)) | (
        (y >= ry + radius) & (y <= ry + rh - radius)
    )
    dx = x - cx
    dy = y - cy
    in_corner = (dx * dx + dy * dy) <= radius * radius
    return inside & (in_cross | in_corner)


def in_oval(x, y, ox, oy, ow, oh):
    cx = ox + ow / 2
    cy = oy + oh / 2
    dx = (x - cx) / (ow / 2)
    dy = (y - cy) / (oh / 2)
    return (dx * dx + dy * dy) <= 1


def render_icon(tone: str, pose: dict) -> Image.Image:
    if tone == "orange":
        fill, eye = ORANGE, EYE
    elif tone == "red":
        fill, eye = RED, EYE_RED
    else:
        fill, eye = GREY, EYE_GREY

    scale = PIXELS_PER_PT * SUPERSAMPLE
    size = POINT * scale
    ys, xs = np.mgrid[0:size, 0:size]
    # AppKit's origin is the bottom left. Pixel centres, supersampled.
    px = (xs + 0.5) / scale
    py = (size - ys - 0.5) / scale

    bob = pose["bob"]
    centre_x = 9.0
    centre_y = 9.0 + bob
    fit = fit_scale(pose, centre_x, centre_y)
    sx = pose["squash_x"] * fit
    sy = pose["squash_y"] * fit
    if abs(sx) < 1e-6:
        sx = 1e-6
    if abs(sy) < 1e-6:
        sy = 1e-6

    dx = px - (centre_x + pose["shake"])
    dy = py - centre_y
    cosine = math.cos(-pose["rotation"])
    sine = math.sin(-pose["rotation"])
    rx = cosine * dx - sine * dy
    ry = sine * dx + cosine * dy
    lx = rx / sx + centre_x
    ly = ry / sy + centre_y

    face = in_round_rect(lx, ly, 1, 1 + bob, 16, 16, 5)
    eye_width = 2.2
    full_height = 4.6
    gap = 3.0
    open_amount = min(1.0, max(0.15, pose["eye_open"]))
    height = full_height * open_amount
    eye_centre_y = 8.6 + full_height / 2 + bob
    eye_y = eye_centre_y - height / 2
    left_x = 9 - (eye_width * 2 + gap) / 2 + pose["eye_shift"]
    right_x = left_x + eye_width + gap
    eyes = in_oval(lx, ly, left_x, eye_y, eye_width, height) | in_oval(
        lx, ly, right_x, eye_y, eye_width, height
    )

    image = np.zeros((size, size, 4), dtype=np.float32)
    # The menu bar cube is the status colour only. Bot colours live in the panel.
    image[face] = fill
    image[eyes] = eye
    big = Image.fromarray(image.astype(np.uint8), "RGBA")
    out = POINT * PIXELS_PER_PT
    return big.resize((out, out), Image.Resampling.BOX)


TEAM_COLOURS = {
    "Agent1": (59, 130, 246),
    "Agent2": (246, 226, 122),
    "Agent3": (236, 72, 153),
}


def scene_for(icon: Image.Image, caption: str, team: list[tuple[str, str, str, str]]) -> Image.Image:
    """480x150 points at 2x. Left: the menu bar cube. Right: three panel rows.

    Each row's face is filled with that bot's colour. The status shows in the
    face's expression and the row around it, the same as the app's panel.
    """
    width, height = 960, 300
    frame = Image.new("RGBA", (width, height), (246, 246, 247, 255))
    draw = ImageDraw.Draw(frame)
    draw.rounded_rectangle((16, 16, 300, 284), radius=28, fill=(255, 255, 255, 255), outline=(220, 220, 224, 255), width=2)
    frame.alpha_composite(icon, ((316 - icon.width) // 2, 44))
    label = font("medium", 22)
    tw = draw.textbbox((0, 0), caption, font=label)[2]
    draw.text(((316 - tw) / 2, 222), caption, fill=(60, 60, 67, 255), font=label)
    sub = font("regular", 15)
    note = "menu bar"
    nw = draw.textbbox((0, 0), note, font=sub)[2]
    draw.text(((316 - nw) / 2, 252), note, fill=(142, 142, 147, 255), font=sub)

    draw.rounded_rectangle((316, 16, 944, 284), radius=28, fill=(255, 255, 255, 255), outline=(220, 220, 224, 255), width=2)
    name_font = font("semibold", 24)
    task_font = font("regular", 21)
    tail_font = font("semibold", 20)
    for index, (name, status, task, trailing) in enumerate(team):
        top = 30 + index * 82
        box = (330, top, 930, top + 74)
        if status == "working":
            draw.rounded_rectangle(box, radius=18, fill=(254, 240, 220, 255), outline=(243, 156, 40, 255), width=2)
            tail_fill = (116, 62, 0, 255)
        elif status == "failed":
            draw.rounded_rectangle(box, radius=18, fill=(252, 228, 229, 255))
            tail_fill = (154, 27, 35, 255)
        elif status == "done":
            draw.rounded_rectangle(box, radius=18, fill=(232, 246, 237, 255))
            tail_fill = (18, 90, 49, 255)
        else:
            draw.rounded_rectangle(box, radius=18, fill=(246, 246, 247, 255))
            tail_fill = (110, 110, 115, 255)
        draw_mini_face(frame, (346, top + 13), 48, status, TEAM_COLOURS[name], 48)
        draw = ImageDraw.Draw(frame)
        draw.text((410, top + 10), name, font=name_font, fill=(22, 21, 27, 255))
        if task:
            draw.text((410, top + 40), task, font=task_font, fill=(74, 72, 85, 255))
        tail_w = draw.textbbox((0, 0), trailing, font=tail_font)[2]
        draw.text((910 - tail_w, top + 25), trailing, font=tail_font, fill=tail_fill)
    return frame.convert("RGB")


def timeline(frame: int) -> tuple[str, dict, str, list]:
    """12 fps, 60 frames, 5.0s. Idle, one bot working, two working, one done, one failed."""
    time = frame / 12.0
    idle = ("idle", "", "Idle")
    if frame <= 5:
        return "grey", grey_pose(time, False, 0, 0.45), "Idle", [
            ("Agent1",) + idle, ("Agent2",) + idle, ("Agent3",) + idle]
    if frame <= 22:
        move = None if frame <= 11 else "twirl"
        pose = orange_pose(time, move, 12 / 12, 11 / 12)
        return "orange", pose, "Working", [
            ("Agent1", "working", "drafting the homepage", "4m"), ("Agent2",) + idle, ("Agent3",) + idle]
    if frame <= 32:
        return "orange", orange_pose(time, "hop", 23 / 12, 10 / 12), "Working", [
            ("Agent1", "working", "drafting the homepage", "5m"),
            ("Agent2", "working", "updating the panel", "1m"), ("Agent3",) + idle]
    if frame <= 42:
        return "orange", orange_pose(time, "wiggle", 33 / 12, 10 / 12), "Working", [
            ("Agent1", "done", "drafting the homepage", "Done"),
            ("Agent2", "working", "updating the panel", "2m"), ("Agent3",) + idle]
    return "red", red_pose(time, True, 43 / 12), "Failed", [
        ("Agent1", "done", "drafting the homepage", "Done"),
        ("Agent2", "done", "updating the panel", "Done"),
        ("Agent3", "failed", "export slides", "Failed")]


def save_gif(frames: list[Image.Image], path: Path) -> None:
    # One shared palette and disposal 2 so a frame does not smear onto the next.
    # Build the palette from every frame so orange and red survive.
    sheet = Image.new("RGB", (frames[0].width, frames[0].height * len(frames)))
    for i, f in enumerate(frames):
        sheet.paste(f, (0, i * f.height))
    palette = sheet.quantize(colors=128, method=Image.Quantize.MEDIANCUT)
    quantized = [
        frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames
    ]
    quantized[0].save(
        path,
        save_all=True,
        append_images=quantized[1:],
        duration=83,
        loop=0,
        disposal=2,
        optimize=False,
    )


def render_gif() -> None:
    frames = []
    for index in range(60):
        tone, pose, caption, team = timeline(index)
        frames.append(scene_for(render_icon(tone, pose), caption, team))
    save_gif(frames, DOCS / "demo.gif")


FONT_FILES = {
    "regular": "Inter-Regular.ttf",
    "medium": "Inter-Medium.ttf",
    "semibold": "Inter-SemiBold.ttf",
    "bold": "Inter-Bold.ttf",
    "mono": "JetBrainsMono-Regular.ttf",
}
FONT_DIRS = [
    Path("/usr/share/fonts/truetype/macos"),
    Path.home() / "Library/Fonts",
    Path("/Library/Fonts"),
]


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    """Inter if it is installed, otherwise DejaVu Sans, so the script runs anywhere."""
    for folder in FONT_DIRS:
        candidate = folder / FONT_FILES[name]
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    fallback = "DejaVuSansMono.ttf" if name == "mono" else ("DejaVuSans.ttf" if name == "regular" else "DejaVuSans-Bold.ttf")
    return ImageFont.truetype(fallback, size)


INK = (22, 21, 27, 255)
INK2 = (74, 72, 85, 255)
FACE_INK = (26, 20, 16, 255)
ORANGE_TEXT = (116, 62, 0, 255)
RED_TEXT = (154, 27, 35, 255)
GREEN_TEXT = (18, 90, 49, 255)
DONE_GREEN = (46, 184, 102, 255)
LOST_FACE = (17, 17, 19)
LOST_INK = (247, 246, 250, 255)
LOST_INK2 = (201, 198, 211, 255)
PANEL_WASH = (255, 255, 255, 128)
CARD_WASH = (255, 255, 255, 184)


def mix_rgb(base: tuple[int, int, int], other: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    return tuple(int(round(base[i] + (other[i] - base[i]) * amount)) for i in range(3))


def is_light(rgb: tuple[int, int, int]) -> bool:
    """Same test as BotAccent.isLight: dark features when they contrast better."""

    def linear(channel: int) -> float:
        value = channel / 255
        if value <= 0.04045:
            return value / 12.92
        return ((value + 0.055) / 1.055) ** 2.4

    luminance = 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
    dark_contrast = (luminance + 0.05) / 0.05
    light_contrast = 1.05 / (luminance + 0.05)
    return dark_contrast >= light_contrast


def quad(start: tuple[float, float], control: tuple[float, float], end: tuple[float, float], steps: int = 14) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for index in range(steps + 1):
        t = index / steps
        u = 1 - t
        points.append((
            u * u * start[0] + 2 * u * t * control[0] + t * t * end[0],
            u * u * start[1] + 2 * u * t * control[1] + t * t * end[1],
        ))
    return points


def draw_chevron(draw: ImageDraw.ImageDraw, x: float, y: float, size: float, fill) -> None:
    """A drawn ▾, so the still does not depend on a font glyph."""
    mid = x + size / 2
    draw.line([(x, y), (mid, y + size * 0.62), (x + size, y)], fill=fill, width=max(2, int(size * 0.16)), joint="curve")


def gear_image(diameter: int, fill: tuple[int, int, int, int]) -> Image.Image:
    """A thin gear, drawn large and scaled down so the teeth do not fill in."""
    scale = 4
    side = diameter * scale
    tile = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    pen = ImageDraw.Draw(tile)
    cx = cy = side / 2
    radius = side * 0.30
    width = max(2, int(side * 0.035))
    pen.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=fill, width=width)
    inner = radius * 0.46
    pen.ellipse((cx - inner, cy - inner, cx + inner, cy + inner), outline=fill, width=width)
    for step in range(6):
        angle = step * math.pi / 3 + math.pi / 6
        x0 = cx + math.cos(angle) * radius * 0.82
        y0 = cy + math.sin(angle) * radius * 0.82
        x1 = cx + math.cos(angle) * radius * 1.28
        y1 = cy + math.sin(angle) * radius * 1.28
        pen.line([(x0, y0), (x1, y1)], fill=fill, width=width)
    return tile.resize((diameter, diameter), Image.Resampling.LANCZOS)


def draw_check(draw: ImageDraw.ImageDraw, x: float, y: float, size: float, fill) -> None:
    width = max(2, int(round(size * 0.18)))
    draw.line(
        [(x, y + size * 0.55), (x + size * 0.36, y + size * 0.92), (x + size, y + size * 0.12)],
        fill=fill,
        width=width,
        joint="curve",
    )


def draw_mini_face(
    base: Image.Image,
    origin: tuple[float, float],
    size: float,
    status: str,
    fill: tuple[int, int, int],
    points: float,
) -> None:
    """Glossy cube. The fill is the bot colour. Status only changes the features.

    "lost" is the maybe-stale face: black, a light rim, and 404 where the eyes go.
    """
    lost = status == "lost"
    if lost:
        fill = LOST_FACE
    light = False if lost else is_light(fill)
    ink = (26, 20, 16, 255) if light else (255, 255, 255, 255)
    top = mix_rgb(fill, (255, 255, 255), 0.14 if lost else 0.28)
    edge = mix_rgb(fill, (0, 0, 0), 0.6 if lost else 0.22)
    side = max(1, int(round(size)))
    tile = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    radius = 8.5 / 32 * side
    plate = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle((0, 0, side - 1, side - 1), radius=radius, fill=edge + (255,))
    tile.alpha_composite(plate)

    body_h = max(1, int(round(28.4 / 32 * side)))
    gradient = Image.new("RGBA", (side, body_h))
    pixels = gradient.load()
    for yy in range(body_h):
        t = yy / max(1, body_h - 1)
        if t <= 0.55:
            color = mix_rgb(top, fill, t / 0.55)
        else:
            color = mix_rgb(fill, edge, (t - 0.55) / 0.45)
        for xx in range(side):
            pixels[xx, yy] = color + (255,)
    mask = Image.new("L", (side, body_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, side - 1, max(1, body_h - 1)), radius=radius, fill=255)
    gradient.putalpha(ImageChops.multiply(gradient.getchannel("A"), mask))
    tile.alpha_composite(gradient, (0, 0))

    pen = ImageDraw.Draw(tile)
    unit = side / 32
    shine = (0, 0, 0, 36) if light else (255, 255, 255, 56 if lost else 158)
    pen.rounded_rectangle((6 * unit, 4 * unit, 20 * unit, 7.4 * unit), radius=1.7 * unit, fill=shine)
    if points >= 20 and not lost:
        dot = 1.3 * unit
        pen.ellipse(
            ((24 - dot) * unit, (5.7 - dot) * unit, (24 + dot) * unit, (5.7 + dot) * unit),
            fill=(255, 255, 255, 217 if light else 191),
        )

    def eye(cx: float, cy: float, radius_units: float, catchlight: bool) -> None:
        pen.ellipse(
            ((cx - radius_units) * unit, (cy - radius_units) * unit, (cx + radius_units) * unit, (cy + radius_units) * unit),
            fill=ink,
        )
        if catchlight:
            catch = (255, 255, 255, 255) if light else (0, 0, 0, 89)
            cr = 0.8 * unit
            ccx = (cx + 0.9) * unit
            ccy = (cy - 0.9) * unit
            pen.ellipse((ccx - cr, ccy - cr, ccx + cr, ccy + cr), fill=catch)

    def stroke(start: tuple[float, float], control: tuple[float, float], end: tuple[float, float], width: float) -> None:
        pen.line(
            quad((start[0] * unit, start[1] * unit), (control[0] * unit, control[1] * unit), (end[0] * unit, end[1] * unit)),
            fill=ink,
            width=max(1, int(round(width * unit))),
            joint="curve",
        )

    if lost:
        label_font = font("bold", max(1, int(round(max(7.5, 10.5 * points / 32) * side / points))))
        bbox = pen.textbbox((0, 0), "404", font=label_font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        pen.text(((side - tw) / 2 - bbox[0], (28.4 * unit - th) / 2 - bbox[1]), "404", font=label_font, fill=ink)
        pen.rounded_rectangle((0, 0, side - 1, side - 1), radius=radius, outline=(255, 255, 255, 82), width=max(1, int(round(side / points))))
    elif status == "working":
        eye(11, 15, 2.7, points >= 20)
        eye(21, 15, 2.7, points >= 20)
        smile = quad((12.6 * unit, 20.2 * unit), (16 * unit, 24.6 * unit), (19.4 * unit, 20.2 * unit))
        pen.polygon(smile, fill=ink)
    elif status == "done":
        stroke((8.4, 16.2), (11, 12.4), (13.6, 16.2), 2.2)
        stroke((18.4, 16.2), (21, 12.4), (23.6, 16.2), 2.2)
        smile = quad((11.6 * unit, 19.6 * unit), (16 * unit, 25.4 * unit), (20.4 * unit, 19.6 * unit))
        pen.polygon(smile, fill=ink)
    elif status == "failed":
        pen.line([(8.6 * unit, 12.2 * unit), (13.2 * unit, 13.8 * unit)], fill=ink, width=max(1, int(round(1.8 * unit))))
        pen.line([(23.4 * unit, 12.2 * unit), (18.8 * unit, 13.8 * unit)], fill=ink, width=max(1, int(round(1.8 * unit))))
        eye(11, 16.6, 2.3, False)
        eye(21, 16.6, 2.3, False)
        stroke((12.4, 23.4), (16, 20), (19.6, 23.4), 2)
    else:
        for cx, width in ((11, 4.4), (21, 4.4), (16, 2.8)):
            y = 16 if cx != 16 else 21.4
            pen.rounded_rectangle(
                ((cx - width / 2) * unit, (y - 1) * unit, (cx + width / 2) * unit, (y + 1) * unit),
                radius=unit,
                fill=ink,
            )

    base.alpha_composite(tile, (int(round(origin[0])), int(round(origin[1]))))


def render_panel() -> None:
    """Light panel at 2x. Faces are each bot's colour. Status is the card, not the fill."""
    scale = 2
    width = 328 * scale
    height = 518 * scale
    wallpaper = Image.new("RGB", (width, height), (214, 210, 224))
    paint = ImageDraw.Draw(wallpaper)
    paint.ellipse((-120, -80, 360, 420), fill=(255, 168, 92))
    paint.ellipse((220, 80, 760, 640), fill=(120, 168, 220))
    paint.ellipse((40, 360, 520, 900), fill=(186, 150, 214))
    wallpaper = wallpaper.filter(ImageFilter.GaussianBlur(36))
    veil = Image.new("RGBA", (width, height), PANEL_WASH)
    image = Image.alpha_composite(wallpaper.convert("RGBA"), veil)
    draw = ImageDraw.Draw(image)

    def px(value: float) -> float:
        return value * scale

    def refresh() -> None:
        nonlocal draw
        draw = ImageDraw.Draw(image)

    def used_font(face: str, size: float) -> ImageFont.FreeTypeFont:
        return font(face, int(size * scale))

    def text_width(value: str, face: str, size: float) -> float:
        bbox = draw.textbbox((0, 0), value, font=used_font(face, size))
        return (bbox[2] - bbox[0]) / scale

    def text(x: float, y: float, value: str, face: str, size: float, fill) -> None:
        draw.text((px(x), px(y)), value, font=used_font(face, size), fill=fill)

    def text_right(right: float, y: float, value: str, face: str, size: float, fill) -> None:
        draw.text((px(right) - px(text_width(value, face, size)), px(y)), value, font=used_font(face, size), fill=fill)

    def paste(layer: Image.Image, dest: tuple[int, int] = (0, 0)) -> None:
        image.alpha_composite(layer, dest)
        refresh()

    def rounded_tint(box: tuple[float, float, float, float], color: tuple[int, int, int], alpha: float) -> None:
        x0, y0, x1, y1 = (int(round(px(v))) for v in box)
        overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).rounded_rectangle(
            (x0, y0, x1, y1),
            radius=px(14),
            fill=color + (int(255 * alpha),),
        )
        paste(overlay)

    def card(box: tuple[float, float, float, float], tint: tuple[int, int, int] | None = None, tint_alpha: float = 0) -> None:
        x0, y0, x1, y1 = (px(v) for v in box)
        draw.rounded_rectangle((x0, y0, x1, y1), radius=px(14), fill=CARD_WASH)
        if tint is not None and tint_alpha:
            rounded_tint(box, tint, tint_alpha)
        draw.rounded_rectangle((x0, y0, x1, y1), radius=px(14), outline=(255, 255, 255, 180), width=max(1, scale))

    def clipped_glow(box: tuple[float, float, float, float]) -> None:
        """Orange radial wash, masked to the card so it cannot spill past the rim."""
        x0, y0, x1, y1 = (int(round(px(v))) for v in box)
        cw, ch = max(1, x1 - x0), max(1, y1 - y0)
        ys, xs = np.mgrid[0:ch, 0:cw]
        dist = np.sqrt(xs.astype(np.float32) ** 2 + (ys - ch / 2) ** 2) / px(90)
        alpha = np.clip(1 - dist, 0, 1) * 51
        layer = np.zeros((ch, cw, 4), dtype=np.uint8)
        layer[..., 0] = 243
        layer[..., 1] = 156
        layer[..., 2] = 40
        layer[..., 3] = alpha.astype(np.uint8)
        glow = Image.fromarray(layer, "RGBA")
        mask = Image.new("L", (cw, ch), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, cw - 1, ch - 1), radius=px(14), fill=255)
        glow.putalpha(ImageChops.multiply(glow.getchannel("A"), mask))
        paste(glow, (x0, y0))

    colours = {
        "Agent1": (59, 130, 246),
        "Agent2": (246, 226, 122),
        "Agent3": (236, 72, 153),
        "Agent4": (31, 41, 55),
        "Agent5": (255, 255, 255),
        "Agent6": (20, 184, 166),
    }

    text(12, 14, "Chief Status", "semibold", 13, INK)
    # Measured gaps only. A separator is drawn between parts, never inside a label.
    summary_y = 32
    parts = [((243, 156, 40), "2 working"), ((229, 72, 77), "1 failed"), (DONE_GREEN[:3], "5 done today")]
    cursor = 12.0
    for index, (color, label) in enumerate(parts):
        if index:
            text(cursor, summary_y, "·", "medium", 11, INK2)
            cursor += text_width("·", "medium", 11) + 6
        dot = 6
        draw.ellipse(
            (px(cursor), px(summary_y + 4), px(cursor + dot), px(summary_y + 4 + dot)),
            fill=color + (255,),
        )
        cursor += dot + 4
        text(cursor, summary_y, label, "medium", 11, INK2)
        cursor += text_width(label, "medium", 11) + 6

    text(16, 56, "WORKING NOW", "semibold", 10, INK2)

    def working_card(top: float, name: str, task: str, elapsed: str) -> None:
        box = (12, top, 316, top + 46)
        card(box, (243, 156, 40), 0.10)
        clipped_glow(box)
        draw_mini_face(image, (px(21), px(top + 9)), px(28), "working", colours[name], 28)
        refresh()
        text(21 + 28 + 10, top + 8, name, "semibold", 13, INK)
        text(21 + 28 + 10, top + 24, task, "regular", 11.5, INK2)
        elapsed_w = text_width(elapsed, "semibold", 12)
        pill_w = 8 + 12 + 6 + elapsed_w + 8
        pill_x = 316 - 10 - pill_w
        draw.rounded_rectangle(
            (px(pill_x), px(top + 12), px(316 - 10), px(top + 34)),
            radius=px(7),
            fill=(243, 156, 40, 41),
        )
        draw.ellipse((px(pill_x + 8), px(top + 17), px(pill_x + 20), px(top + 29)), fill=(243, 156, 40, 90))
        draw.ellipse((px(pill_x + 11), px(top + 20), px(pill_x + 17), px(top + 26)), fill=(243, 156, 40, 255))
        text(pill_x + 22, top + 15, elapsed, "semibold", 12, ORANGE_TEXT)

    def lost_card(top: float, name: str, task: str, label: str) -> None:
        """A working bot with no post for 30 min: black card, 404 face, maybe stale."""
        box = (12, top, 316, top + 46)
        x0, y0, x1, y1 = (int(round(px(v))) for v in box)
        layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        pen = ImageDraw.Draw(layer)
        pen.rounded_rectangle((x0, y0, x1, y1), radius=px(14), fill=LOST_FACE + (235,))
        pen.rounded_rectangle((x0, y0, x1, y1), radius=px(14), outline=(255, 255, 255, 72), width=max(1, scale))
        paste(layer)
        draw_mini_face(image, (px(21), px(top + 9)), px(28), "lost", colours[name], 28)
        refresh()
        text(21 + 28 + 10, top + 8, name, "semibold", 13, LOST_INK)
        text(21 + 28 + 10, top + 24, task, "regular", 11.5, LOST_INK2)
        label_w = text_width(label, "semibold", 11)
        pill_w = 7 + 9 + 5 + label_w + 7
        pill_x = 316 - 10 - pill_w
        pill = Image.new("RGBA", image.size, (0, 0, 0, 0))
        ImageDraw.Draw(pill).rounded_rectangle(
            (px(pill_x), px(top + 12), px(316 - 10), px(top + 34)), radius=px(7), fill=(255, 255, 255, 33))
        paste(pill)
        draw.ellipse((px(pill_x + 7), px(top + 18.5), px(pill_x + 16), px(top + 27.5)), outline=LOST_INK2, width=max(1, int(1.5 * scale)))
        text(pill_x + 21, top + 16, label, "semibold", 11, LOST_INK)

    # Fresh cards first, longest running first. A bot quiet for 30+ min drops below, in black.
    working_card(72, "Agent1", "drafting the homepage", "4m")
    lost_card(124, "Agent2", "updating the panel", "maybe stale · 34m")

    team_box = (12, 178, 316, 306)
    card(team_box)
    team = [
        ("Agent3", "failed", "export slides", "Failed · 3m ago", RED_TEXT),
        ("Agent4", "done", "word list", "Done · 12m ago", GREEN_TEXT),
        ("Agent5", "idle", "", "Idle · 2h ago", INK2),
        ("Agent6", "idle", "", "Idle · 3h ago", INK2),
    ]
    for index, (name, status, task, trailing, trailing_fill) in enumerate(team):
        top = 178 + index * 32
        if status == "failed":
            band = Image.new("RGBA", image.size, (0, 0, 0, 0))
            ImageDraw.Draw(band).rectangle((px(12), px(top), px(316), px(top + 32)), fill=(229, 72, 77, 26))
            mask = Image.new("L", image.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle(
                tuple(px(v) for v in team_box),
                radius=px(14),
                fill=255,
            )
            band.putalpha(ImageChops.multiply(band.getchannel("A"), mask))
            paste(band)
        if index:
            draw.line([(px(21), px(top)), (px(306), px(top))], fill=(22, 21, 27, 26), width=1)
        draw_mini_face(image, (px(21), px(top + 6)), px(20), status, colours[name], 20)
        refresh()
        name_x = 21 + 20 + 8
        text(name_x, top + 8, name, "semibold", 12.5, INK)
        if status == "done":
            draw_check(draw, px(name_x + text_width(name, "semibold", 12.5) + 3), px(top + 11), px(8), GREEN_TEXT)
        if task:
            text(name_x + 72, top + 8, task, "regular", 12, INK2)
        text_right(306, top + 9, trailing, "semibold" if status != "idle" else "medium", 11, trailing_fill)

    card((12, 306, 316, 462), DONE_GREEN[:3], 0.06)
    draw_chevron(draw, px(22), px(316), px(8), INK)
    text(36, 313, "Finished today", "semibold", 12, INK)
    chip = "5"
    chip_x = 36 + text_width("Finished today", "semibold", 12) + 6
    chip_w = text_width(chip, "semibold", 10.5) + 12
    draw.rounded_rectangle((px(chip_x), px(313), px(chip_x + chip_w), px(327)), radius=px(6), fill=(46, 184, 102, 41))
    text(chip_x + 6, 314, chip, "semibold", 10.5, GREEN_TEXT)
    text_right(306, 314, "2h 19m total", "medium", 11, INK2)
    jobs = [
        ("Agent4", "word list", "1h 12m"),
        ("Agent2", "panel look", "9m"),
        ("Agent3", "export slides", "38m"),
        ("Agent6", "inbox triage", "14m"),
        ("Agent1", "morning brief", "6m"),
    ]
    for index, (name, task, duration) in enumerate(jobs):
        top = 336 + index * 24
        draw_mini_face(image, (px(24), px(top + 5)), px(14), "done", colours[name], 14)
        refresh()
        name_x = 24 + 14 + 8
        text(name_x, top + 4, name, "semibold", 12, INK)
        draw_check(draw, px(name_x + text_width(name, "semibold", 12) + 3), px(top + 8), px(8), GREEN_TEXT)
        text(name_x + 70, top + 4, task, "regular", 12, INK2)
        text_right(306, top + 5, duration, "medium", 11, INK2)

    draw.line([(0, px(470)), (width, px(470))], fill=(22, 21, 27, 26), width=max(1, scale // 2))
    text(12, 484, "Updated 8:05 PM", "regular", 11, INK2)

    settings = "Settings"
    quit_label = "Quit  ⌘Q"
    quit_w = text_width(quit_label, "medium", 11.5)
    settings_w = text_width(settings, "medium", 11.5)
    gear = 12
    pad = 8
    pill_w = pad + gear + 4 + settings_w + pad
    pill_right = 316 - quit_w - 8
    pill_x = pill_right - pill_w
    pill_y = 476
    draw.rounded_rectangle(
        (px(pill_x), px(pill_y), px(pill_x + pill_w), px(pill_y + 24)),
        radius=px(7),
        fill=(22, 21, 27, 18),
    )
    gear_px = gear * scale
    icon = gear_image(gear_px, INK)
    image.alpha_composite(icon, (int(round(px(pill_x + pad))), int(round(px(pill_y + 6)))))
    refresh()
    text(pill_x + pad + gear + 4, pill_y + 5, settings, "medium", 11.5, INK)
    text_right(316, 484, quit_label, "medium", 11.5, INK2)

    # Flatten onto white. A direct fill with alpha replaces the pixel, and
    # converting that to RGB would matte it on black (the old Settings blob).
    flat = Image.new("RGB", image.size, (255, 255, 255))
    flat.paste(image, mask=image.getchannel("A"))
    flat.save(DOCS / "panel.png", "PNG")




def render_hero() -> None:
    """docs/hero.png: a desktop, a menu bar with the orange cube, and the panel under it.

    One working bot has gone quiet, so the orange cube carries the small black dot.
    """
    panel = Image.open(DOCS / "panel.png").convert("RGBA")
    width, height = 1600, 1140
    desk = Image.new("RGB", (width, height), (40, 34, 64))
    paint = ImageDraw.Draw(desk)
    paint.ellipse((-300, -200, 900, 900), fill=(255, 150, 70))
    paint.ellipse((700, 100, 1900, 1300), fill=(80, 120, 220))
    paint.ellipse((100, 700, 1100, 1600), fill=(170, 110, 210))
    desk = desk.filter(ImageFilter.GaussianBlur(120)).convert("RGBA")

    bar_h = 48
    bar = Image.new("RGBA", (width, bar_h), (255, 255, 255, 150))
    desk.alpha_composite(bar)
    draw = ImageDraw.Draw(desk)
    menu = font("semibold", 26)
    draw.text((40, 9), "Finder", font=menu, fill=(22, 21, 27, 255))
    regular = font("medium", 24)
    x = 150
    for item in ("File", "Edit", "View", "Go", "Window"):
        draw.text((x, 10), item, font=regular, fill=(22, 21, 27, 255))
        x += draw.textbbox((0, 0), item, font=regular)[2] + 34
    clock = "Sun 8:05 PM"
    cw = draw.textbbox((0, 0), clock, font=regular)[2]
    draw.text((width - 40 - cw, 10), clock, font=regular, fill=(22, 21, 27, 255))

    icon = render_icon("orange", orange_pose(0.4, None, 0, 0)).resize((40, 40), Image.Resampling.LANCZOS)
    icon_x = width - 40 - cw - 70
    # Drawing with alpha straight onto RGBA replaces pixels, so blend a layer instead.
    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((icon_x - 10, 4, icon_x + 50, 44), radius=8, fill=(255, 255, 255, 120))
    desk.alpha_composite(glow)
    desk.alpha_composite(icon, (icon_x, 4))
    # Small black dot with a light rim, bottom right: another working bot may be stale.
    dot = ImageDraw.Draw(desk)
    dot_x, dot_y, dot_r = icon_x + 33.5, 4 + 33.5, 6.7
    dot.ellipse((dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r), fill=(255, 255, 255, 255))
    inner = dot_r - 2.4
    dot.ellipse((dot_x - inner, dot_y - inner, dot_x + inner, dot_y + inner), fill=LOST_FACE + (255,))

    # Left side: the name and what it does, in plain words.
    draw = ImageDraw.Draw(desk)
    big = font("semibold", 84)
    line = font("medium", 38)
    draw.text((90, 300), "Chief Status", font=big, fill=(255, 255, 255, 255))
    words = ["Who is working, who is done,", "and who got stuck.", "Right in your menu bar."]
    for index, words_line in enumerate(words):
        draw.text((94, 420 + index * 56), words_line, font=line, fill=(255, 255, 255, 230))

    panel_x = min(width - panel.width - 24, icon_x + 20 - panel.width // 2)
    panel_y = bar_h + 24
    mask = Image.new("L", panel.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, panel.width - 1, panel.height - 1), radius=24, fill=255)
    shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (panel_x, panel_y + 16, panel_x + panel.width, panel_y + panel.height + 16), radius=28, fill=(0, 0, 0, 110))
    desk.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    rounded = panel.copy()
    rounded.putalpha(mask)
    desk.alpha_composite(rounded, (panel_x, panel_y))
    desk.convert("RGB").save(DOCS / "hero.png", "PNG", optimize=True)


def render_app_icon() -> None:
    """docs/icon.png, from the app's own icon set."""
    source = ROOT / "menubar" / "AppIcon.iconset" / "icon_256x256@2x.png"
    Image.open(source).convert("RGBA").save(DOCS / "icon.png", "PNG", optimize=True)


def main() -> None:
    render_gif()
    render_panel()
    render_hero()
    render_app_icon()
    for name in ("demo.gif", "panel.png", "hero.png", "icon.png"):
        print(f"wrote {DOCS / name}")


if __name__ == "__main__":
    main()
