"""
Blender Render Monitor hook.

Writes the progress of every render in this Blender process to
~/Library/Application Support/BlenderRenderMonitor/jobs/<pid>.json,
which the Blender Render Monitor Mac app reads.

Two ways to use it:
  * Headless (works with --factory-startup): load it before your own script.
        blender -b --factory-startup file.blend --python render_monitor.py --python my_script.py
        blender -b file.blend --python render_monitor.py -a
  * Interactive: install this file as an add-on (Preferences > Add-ons > Install from Disk).
"""

bl_info = {
    "name": "Render Monitor",
    "author": "Blender Render Monitor",
    "version": (1, 0, 0),
    "blender": (3, 0, 0),
    "location": "Automatic",
    "description": "Reports render progress to the Blender Render Monitor Mac app",
    "category": "Render",
}

import json
import os
import re
import time

import bpy
from bpy.app.handlers import persistent

STATUS_DIR = os.environ.get("BLENDER_RENDER_MONITOR_DIR") or os.path.expanduser(
    "~/Library/Application Support/BlenderRenderMonitor/jobs")
MAX_FRAME_HISTORY = 100
STATS_WRITE_INTERVAL = 1.0

_SAMPLE_RE = re.compile(r"Sample (\d+)\s*/\s*(\d+)", re.IGNORECASE)
_SAMPLES_RE = re.compile(r"Rendering (\d+)\s*/\s*(\d+) samples", re.IGNORECASE)
_REMAINING_RE = re.compile(r"Remaining:\s*(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)")

_state = None
_frame_started = None
_last_stats_write = 0.0


def _status_path():
    return os.path.join(STATUS_DIR, "%d.json" % os.getpid())


def _write():
    if _state is None:
        return
    _state["updatedAt"] = time.time()
    try:
        os.makedirs(STATUS_DIR, exist_ok=True)
        path = _status_path()
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_state, f)
        os.replace(tmp, path)
    except OSError as ex:
        print("[render_monitor] could not write status:", ex)


def _scene_info(scene):
    r = scene.render
    return {
        "blendFile": bpy.data.filepath or "",
        "scene": scene.name,
        "engine": r.engine,
        "outputPath": bpy.path.abspath(r.filepath),
        "resolution": [int(r.resolution_x * r.resolution_percentage / 100),
                       int(r.resolution_y * r.resolution_percentage / 100)],
        "frameStart": scene.frame_start,
        "frameEnd": scene.frame_end,
        "frameStep": max(1, scene.frame_step),
    }


def _ensure_state(scene):
    global _state
    if _state is None:
        _state = {
            "pid": os.getpid(),
            "blenderVersion": bpy.app.version_string,
            "background": bool(bpy.app.background),
            "startedAt": time.time(),
            "status": "rendering",
            "currentFrame": scene.frame_current,
            "currentFrameStartedAt": None,
            "framesRendered": 0,
            "lastCompletedFrame": None,
            "sample": None,
            "samples": None,
            "frameRemaining": None,
            "statsAt": None,
            "frameTimes": [],
        }
    _state.update(_scene_info(scene))


def _first_scene(args):
    for a in args:
        if isinstance(a, bpy.types.Scene):
            return a
    return bpy.context.scene


@persistent
def _on_render_init(*args):
    _ensure_state(_first_scene(args))
    _state["status"] = "rendering"
    _write()


@persistent
def _on_render_pre(*args):
    global _frame_started
    scene = _first_scene(args)
    _ensure_state(scene)
    _frame_started = time.time()
    _state.update(status="rendering", currentFrame=scene.frame_current,
                  currentFrameStartedAt=_frame_started, sample=None, samples=None,
                  frameRemaining=None, statsAt=None)
    _write()


@persistent
def _on_render_post(*args):
    global _frame_started
    if _state is None:
        return
    scene = _first_scene(args)
    now = time.time()
    if _frame_started is not None:
        times = _state["frameTimes"]
        times.append({"frame": scene.frame_current, "seconds": round(now - _frame_started, 3),
                      "finishedAt": now})
        del times[:-MAX_FRAME_HISTORY]
    _frame_started = None
    _state["framesRendered"] += 1
    _state["lastCompletedFrame"] = scene.frame_current
    _state["currentFrameStartedAt"] = None
    _write()


@persistent
def _on_render_complete(*args):
    if _state is None:
        return
    _state["status"] = "complete"
    _write()


@persistent
def _on_render_cancel(*args):
    if _state is None:
        return
    _state["status"] = "cancelled"
    _write()


@persistent
def _on_render_stats(*args):
    global _last_stats_write
    if _state is None:
        return
    text = next((a for a in args if isinstance(a, str)), None)
    if not text:
        return
    m = _SAMPLE_RE.search(text) or _SAMPLES_RE.search(text)
    if not m:
        return
    now = time.time()
    _state["sample"], _state["samples"] = int(m.group(1)), int(m.group(2))
    r = _REMAINING_RE.search(text)
    _state["frameRemaining"] = (int(r.group(1) or 0) * 3600 + int(r.group(2)) * 60 + float(r.group(3))
                                if r else None)
    _state["statsAt"] = now
    if now - _last_stats_write >= STATS_WRITE_INTERVAL:
        _last_stats_write = now
        _write()


_HANDLERS = {
    "render_init": _on_render_init,
    "render_pre": _on_render_pre,
    "render_post": _on_render_post,
    "render_complete": _on_render_complete,
    "render_cancel": _on_render_cancel,
    "render_stats": _on_render_stats,
}


def register():
    for name, fn in _HANDLERS.items():
        handlers = getattr(bpy.app.handlers, name)
        for h in list(handlers):
            if getattr(h, "__name__", None) == fn.__name__ and getattr(h, "__module__", None) == fn.__module__:
                handlers.remove(h)
        handlers.append(fn)


def unregister():
    for name, fn in _HANDLERS.items():
        handlers = getattr(bpy.app.handlers, name)
        if fn in handlers:
            handlers.remove(fn)


if __name__ == "__main__":
    register()
