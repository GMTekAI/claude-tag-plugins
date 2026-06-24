# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
"""chartkit: primitives for polished charts. Import it and write the plot the data deserves.

    import chartkit as ck
    c = ck.theme()                                   # typography + colors, dark-aware
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.bar(labels, values, color=c.accent)
    ck.finish(ax, title="Signups", subtitle="by month", source="prod analytics, 2026-06")
    ck.save(fig, "out/signups", formats=("png", "svg"))
    ck.write_html("out/signups.html", data, COMPONENT_JS)   # offline interactive page

The kit owns the things that should stay consistent (fonts, color derivation,
caption typography, offline html packaging). Everything about the chart itself
is plain matplotlib or Recharts code written by the caller.
"""

import html as _html
import json
import math
import os
import re
import tempfile

# sandboxes often make the home directory unwritable; matplotlib then warns and
# rebuilds its font cache into a fresh temp dir on every run. point it at a
# stable writable cache dir before import so runs stay quiet and reuse the cache.
if "MPLCONFIGDIR" not in os.environ:
    try:
        with tempfile.TemporaryFile(dir=os.path.expanduser("~")):
            pass
    except OSError:
        # shared tmp: namespace the cache by uid and refuse a dir owned by
        # someone else so a pre-created path cannot redirect the cache.
        _uid = os.getuid() if hasattr(os, "getuid") else 0
        _mpl_cfg = os.path.join(tempfile.gettempdir(), f"chartkit-mpl-{_uid}")
        try:
            os.makedirs(_mpl_cfg, mode=0o700, exist_ok=True)
            if hasattr(os, "getuid") and os.stat(_mpl_cfg).st_uid != os.getuid():
                raise OSError("cache dir owned by another user")
            os.environ["MPLCONFIGDIR"] = _mpl_cfg
        except OSError:
            pass  # tmp unwritable too: let matplotlib handle it

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402  (backend must be set first)

# --- defaults ---------------------------------------------------------------

DEFAULT_BG = "#fbf7f2"

# warm categorical series, used when the caller has no brand colors to apply
SERIES = [
    "#d9531e",
    "#3b4a5a",
    "#2f855a",
    "#6b46c1",
    "#c05621",
    "#2b6cb0",
    "#b83280",
    "#4a5568",
]

FONT_MPL = ["Inter", "Helvetica Neue", "Helvetica", "Arial", "DejaVu Sans"]
FONT_CSS = (
    "Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', "
    "'Helvetica Neue', Helvetica, Arial, sans-serif"
)

VENDOR_FILES = [
    "react/react.production.min.js",
    "react-dom/react-dom.production.min.js",
    "react-is/react-is.production.min.js",
    "recharts/Recharts.js",
]

_active = None  # last theme(), used by finish()/write_html() as their default


# --- color math -------------------------------------------------------------


def _rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def _hex(rgb):
    return "#{:02x}{:02x}{:02x}".format(*(max(0, min(255, round(v))) for v in rgb))


def _luminance(hex_color):
    r, g, b = (v / 255 for v in _rgb(hex_color))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def mix(a, b, t):
    """Blend hex color a toward hex color b by t in [0, 1]."""
    ra, rb = _rgb(a), _rgb(b)
    return _hex(tuple(va + (vb - va) * t for va, vb in zip(ra, rb)))


# --- font handling ----------------------------------------------------------


def _font_stacks(user_font):
    if not user_font:
        return FONT_MPL, FONT_CSS
    parts = [f.strip() for f in user_font.split(",") if f.strip()]
    css_parts = [f"'{f}'" if " " in f else f for f in parts]
    return parts + FONT_MPL, ", ".join(css_parts) + ", " + FONT_CSS


# --- primitives -------------------------------------------------------------


def theme(bg=DEFAULT_BG, font=None):
    """Apply the chart baseline and return its resolved colors.

    Foreground colors are derived from the background luminance, so passing a
    dark background produces a correct dark chart with no other changes.
    Returns a namespace: bg, dark, text, muted, grid, spine, accent, secondary,
    series, font_css.
    """
    global _active
    dark = _luminance(bg) < 0.45
    anchor = "#f5f1ea" if dark else "#241c14"
    text = mix(bg, anchor, 0.92)
    muted = mix(bg, anchor, 0.55)
    spine = mix(bg, anchor, 0.35)
    grid = mix(bg, anchor, 0.14)
    font_mpl, font_css = _font_stacks(font)

    plt.rcParams.update(
        {
            "font.family": "sans-serif",
            "font.sans-serif": font_mpl,
            "figure.facecolor": bg,
            "axes.facecolor": bg,
            "savefig.facecolor": bg,
            "text.color": text,
            "axes.edgecolor": spine,
            "axes.labelcolor": muted,
            "xtick.color": muted,
            "ytick.color": muted,
            "xtick.labelsize": 10,
            "ytick.labelsize": 10,
            "axes.titlecolor": text,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "axes.grid.axis": "y",
            "grid.color": grid,
            "grid.linewidth": 0.9,
            "axes.axisbelow": True,
            "legend.frameon": False,
            "legend.fontsize": 10,
        }
    )

    class _Theme:
        pass

    c = _Theme()
    c.bg = bg
    c.dark = dark
    c.text = text
    c.muted = muted
    c.spine = spine
    c.grid = grid
    # the default series is tuned for the light background; on a dark bg, lift
    # each color toward the light anchor so lines stay readable
    c.series = [mix(s, anchor, 0.35) for s in SERIES] if dark else list(SERIES)
    c.accent = c.series[0]
    c.secondary = c.series[1]
    c.font_css = font_css
    _active = c
    return c


def palette(n, base=None):
    """Return n colors. base=None cycles the active theme's series (dark-adjusted
    when the theme is dark), base=hex builds a ramp from that color, base=list
    cycles the list."""
    if base is None:
        src = _active.series if _active else SERIES
    elif isinstance(base, (list, tuple)):
        src = list(base)
    else:
        bg = _active.bg if _active else DEFAULT_BG
        if n == 1:
            return [base]
        # ramp from full strength toward the background, never fully washed out
        return [mix(base, bg, 0.65 * i / (n - 1)) for i in range(n)]
    return [src[i % len(src)] for i in range(n)]


def finish(ax, title=None, subtitle=None, source=None, colors=None):
    """Apply the typographic frame: title, optional subtitle, optional source caption."""
    c = colors or _active or theme()
    fig = ax.figure
    if title:
        ax.set_title(
            title,
            loc="left",
            fontsize=15,
            fontweight="bold",
            color=c.text,
            pad=26 if subtitle else 12,
        )
    if subtitle:
        ax.text(
            0,
            1.03,
            subtitle,
            transform=ax.transAxes,
            fontsize=11,
            color=c.muted,
            va="bottom",
        )
    fig.tight_layout(rect=(0, 0.045 if source else 0, 1, 1))
    if source:
        fig.text(0.012, 0.012, source, fontsize=9, color=c.muted)


def save(fig, stem, formats=("png",), dpi=220):
    """Write the figure once per format. stem has no extension. Returns the paths."""
    os.makedirs(os.path.dirname(os.path.abspath(stem)) or ".", exist_ok=True)
    paths = []
    for ext in formats:
        path = f"{stem}.{ext}"
        fig.savefig(path, dpi=dpi, bbox_inches="tight")
        paths.append(path)
    plt.close(fig)
    return paths


# --- offline interactive html ------------------------------------------------


def _find_third_party_dir():
    # explicit override first; otherwise walk up from this file toward the repo
    # root looking for a third_party/ that carries every vendor bundle
    override = os.environ.get("CHARTKIT_THIRD_PARTY")
    if override and all(
        os.path.isfile(os.path.join(override, f)) for f in VENDOR_FILES
    ):
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    seen = set()
    while here and here not in seen:
        seen.add(here)
        cand = os.path.join(here, "third_party")
        if all(os.path.isfile(os.path.join(cand, f)) for f in VENDOR_FILES):
            return cand
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent
    cand = os.path.join(os.getcwd(), "third_party")
    if all(os.path.isfile(os.path.join(cand, f)) for f in VENDOR_FILES):
        return cand
    return None


def _vendor_scripts():
    root = _find_third_party_dir()
    if not root:
        # fail loudly: a page without these bundles renders blank, and the
        # docstring promises a self-contained file
        raise FileNotFoundError(
            "chartkit.write_html: could not locate the vendored React/Recharts "
            "bundles under any third_party/ ancestor of "
            f"{os.path.abspath(__file__)!r}. Set CHARTKIT_THIRD_PARTY to the "
            "directory that holds " + ", ".join(VENDOR_FILES)
        )
    parts = []
    for f in VENDOR_FILES:
        with open(os.path.join(root, f), "r", encoding="utf-8") as fh:
            parts.append(f"<!-- {f} -->\n<script>\n{fh.read()}\n</script>")
    return "\n".join(parts), True


# characters with no structural meaning inside a css declaration block; a value
# that fails this never describes a real color or font stack.
_CSS_VALUE_RE = re.compile(r"^[\w#(),.%'\" /-]+$")


def _css_value(value, what):
    if not _CSS_VALUE_RE.fullmatch(value):
        raise ValueError(f"{what} contains characters unsafe for css: {value!r}")
    return value


def write_html(out_path, data, component_js, *, title="", bg=None, font=None):
    """Write a self-contained interactive page.

    data is any JSON-serializable value, exposed as window.__CHART_DATA__.
    component_js is a script that reads it and renders into #root using
    window.React, window.ReactDOM and window.Recharts (all inlined from
    third_party/, so the file opens offline). Returns (path, inlined_bool).
    """
    c = _active
    bg = bg or (c.bg if c else DEFAULT_BG)
    _, font_css = _font_stacks(font) if font else (None, c.font_css if c else FONT_CSS)
    scripts_html, inlined = _vendor_scripts()
    # data and title may carry arbitrary strings: keep the json inert inside the
    # script block, entity-escape the title, and allowlist the css values so
    # nothing breaks out of its tag or smuggles extra declarations into the css.
    data_js = (
        json.dumps(data)
        .replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
    )
    safe_title = _html.escape(title or "chart")
    safe_bg = _css_value(bg, "bg")
    safe_font_css = _css_value(font_css, "font")
    page = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{safe_title}</title>
<style>
  html, body {{ margin: 0; padding: 0; background: {safe_bg}; font-family: {safe_font_css}; }}
  svg text {{ font-family: {safe_font_css}; }}
  * {{ box-sizing: border-box; }}
</style></head><body>
<div id="root"></div>
{scripts_html}
<script>
window.__CHART_DATA__ = {data_js};
</script>
<script>{component_js}</script>
</body></html>"""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(page)
    return out_path, inlined


# --- small data helpers (optional, use only when they fit) -------------------


def zero_fill_days(pairs):
    """[(date, value), ...] with duplicate dates summed and missing days as 0.
    Returns (sorted dates, values)."""
    import datetime as dt

    agg = {}
    for d, v in pairs:
        agg[d] = agg.get(d, 0.0) + v
    if not agg:
        return [], []
    lo, hi = min(agg), max(agg)
    days = [lo + dt.timedelta(days=i) for i in range((hi - lo).days + 1)]
    return days, [agg.get(d, 0.0) for d in days]


def rolling_mean(values, window):
    """Trailing rolling mean. Early points average what is available so far."""
    if window <= 1:
        return list(values)
    out = []
    for i in range(len(values)):
        lo = max(0, i - window + 1)
        out.append(sum(values[lo : i + 1]) / (i - lo + 1))
    return out


def log_floor(values):
    """A y-axis lower bound one decade below the smallest positive value, so
    log-scale bars keep visible height."""
    pos = [v for v in values if v > 0]
    if not pos:
        return None
    return 10 ** (math.floor(math.log10(min(pos))) - 1)
