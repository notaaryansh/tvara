"""Streamlit UI for browsing geometric icon candidates for tvara.

Pick a pattern family from the sidebar, slide parameters around until
something clicks, then hit Export. The exported PNG goes into
`experiments/icongen/output/` at 1024×1024 (the source size you want for
generating an `.icns`).

Run:
    cd experiments/icongen
    streamlit run app.py
"""

from __future__ import annotations

import io
import os
from datetime import datetime

import streamlit as st

import patterns


st.set_page_config(
    page_title="tvara icon generator",
    layout="wide",
    initial_sidebar_state="expanded",
)

# Streamlit caches the rasterized PIL image across reruns when the
# parameter tuple is unchanged. Keeps live tweaking snappy.
@st.cache_data(show_spinner=False)
def _render(pattern_name: str, params_tuple: tuple, fg: str, bg: str,
            zoom: float, rot: float, pan_x: float, pan_y: float):
    spec = patterns.PATTERNS[pattern_name]
    params = dict(zip(spec["defaults"].keys(), params_tuple))
    prims = spec["fn"](**params)
    img = patterns.render(prims, fg=fg, bg=bg,
                          zoom=zoom, rotation_deg=rot,
                          pan_x=pan_x, pan_y=pan_y)
    return img


# ---- Sidebar: pattern + params ----
st.sidebar.title("tvara icon")
st.sidebar.caption("Geometric pattern designer")

pattern_name = st.sidebar.selectbox(
    "Pattern family", list(patterns.PATTERNS.keys()), index=0,
)

st.sidebar.markdown("### Pattern parameters")
spec = patterns.PATTERNS[pattern_name]
param_values: list = []
for key, (lo, hi, default, step) in spec["defaults"].items():
    if isinstance(default, int) and isinstance(step, int):
        v = st.sidebar.slider(key, lo, hi, default, step)
    else:
        v = st.sidebar.slider(
            key, float(lo), float(hi), float(default), float(step),
        )
    param_values.append(v)

st.sidebar.markdown("### Colors")
bg = st.sidebar.color_picker("Background", "#0a0a14")
fg = st.sidebar.color_picker("Foreground", "#f5f5f7")

st.sidebar.markdown("### Transform")
zoom = st.sidebar.slider("Zoom", 0.3, 3.0, 1.0, 0.01)
rotation = st.sidebar.slider("Rotation (°)", 0.0, 360.0, 0.0, 1.0)
pan_x = st.sidebar.slider("Pan X", -1.0, 1.0, 0.0, 0.01)
pan_y = st.sidebar.slider("Pan Y", -1.0, 1.0, 0.0, 0.01)

# ---- Main area: preview + export ----
st.markdown(
    "<h2 style='margin-bottom: 0.2em;'>tvara icon generator</h2>"
    "<p style='color: #888; margin-top: 0;'>"
    "Tweak parameters live, then export at 1024×1024 to use as the .icns source."
    "</p>",
    unsafe_allow_html=True,
)

img = _render(pattern_name, tuple(param_values),
              fg, bg, zoom, rotation, pan_x, pan_y)

preview_col, side_col = st.columns([3, 1])
with preview_col:
    # Display at fixed pixel size so the preview reads like the actual
    # icon size — Streamlit's auto-width tends to upscale and hide jagged
    # edges.
    st.image(img, width=640)

with side_col:
    st.markdown("### Export")

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    st.download_button(
        "Download PNG (1024×1024)",
        data=buf.getvalue(),
        file_name="tvara-icon.png",
        mime="image/png",
        use_container_width=True,
    )

    if st.button("Save to output/", use_container_width=True):
        out_dir = os.path.join(os.path.dirname(__file__), "output")
        os.makedirs(out_dir, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{pattern_name.lower().replace(' ', '_')}_{ts}.png"
        path = os.path.join(out_dir, filename)
        img.save(path)
        st.success(f"Saved {filename}")

    st.markdown("### Current parameters")
    st.markdown(
        "Useful for sharing a config back to Claude when you've "
        "found one you like."
    )
    config_summary = {
        "pattern": pattern_name,
        "params": dict(zip(spec["defaults"].keys(), param_values)),
        "fg": fg,
        "bg": bg,
        "zoom": zoom,
        "rotation_deg": rotation,
        "pan_x": pan_x,
        "pan_y": pan_y,
    }
    st.json(config_summary, expanded=False)

    st.markdown("### Tips")
    st.markdown(
        "- **Phyllotaxis** at angle 137.508° = sunflower seed pattern; "
        "tiny deviations (~137.3°, ~137.7°) shatter into different shapes.\n"
        "- **Lissajous**: integer-ratio a:b closes into a knot; "
        "non-integer ratios precess.\n"
        "- **Truchet**: same seed + same grid = same pattern, useful for "
        "iteration.\n"
        "- App icons read best with strong **central focus** — increase "
        "zoom or pan to crop to the most legible portion."
    )
