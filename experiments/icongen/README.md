# tvara icon generator

Interactive Streamlit app for generating geometric app-icon candidates.
Slide parameters around live, pan/zoom/rotate, export a 1024×1024 PNG,
hand the file (or just the JSON config) to Claude and it'll bake the
proper `tvara.icns`.

## Quick start

From the repo root:

```bash
cd experiments/icongen
streamlit run app.py
```

Streamlit opens a tab at `http://localhost:8501`. Use the sidebar:

1. Pick a **pattern family** (Phyllotaxis, Flower of Life, Lissajous,
   Mandala, Truchet, Hypotrochoid, Sierpinski Triangle).
2. Tweak the **pattern parameters** — every value is live.
3. Set **foreground / background** colors.
4. Use **zoom / rotation / pan** to crop into the part that reads as an
   icon.
5. Hit **Save to output/** (saves under `output/<pattern>_<timestamp>.png`)
   or **Download PNG** (browser download).

The exported PNG is 1024×1024 RGB — exactly what `iconutil` wants as the
top of an `.iconset` for `.icns` conversion.

## How to share a config back

The sidebar shows a JSON blob of every current parameter. If a particular
combination clicks but you want me to nudge it, paste that JSON and I'll
reproduce the exact pattern then refine it.

## Adding new pattern families

Add a function in `patterns.py` that returns a list of `Stroke` / `Circle`
/ `Dot` primitives in design space (centered on (0, 0) with extent roughly
[-1, 1]). Register it in the `PATTERNS` dict at the bottom with its
slider defaults `(min, max, default, step)`. The Streamlit UI picks it up
automatically.

## Output → real `.icns`

Once a 1024×1024 PNG is chosen:

```bash
# Picked file → tvara.iconset (Apple's required directory layout)
mkdir tvara.iconset
sips -z 16   16   chosen.png --out tvara.iconset/icon_16x16.png
sips -z 32   32   chosen.png --out tvara.iconset/icon_16x16@2x.png
sips -z 32   32   chosen.png --out tvara.iconset/icon_32x32.png
sips -z 64   64   chosen.png --out tvara.iconset/icon_32x32@2x.png
sips -z 128  128  chosen.png --out tvara.iconset/icon_128x128.png
sips -z 256  256  chosen.png --out tvara.iconset/icon_128x128@2x.png
sips -z 256  256  chosen.png --out tvara.iconset/icon_256x256.png
sips -z 512  512  chosen.png --out tvara.iconset/icon_256x256@2x.png
sips -z 512  512  chosen.png --out tvara.iconset/icon_512x512.png
cp chosen.png tvara.iconset/icon_512x512@2x.png
iconutil -c icns tvara.iconset
```

Drop `tvara.icns` into `Sources/tvara/Resources/`, add
`<key>CFBundleIconFile</key><string>tvara</string>` to `Info.plist`, and
the next release build picks it up. Claude can do all this for you in one
command once you pick the design.
