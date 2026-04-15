# SimpleDisplay — Brand Assets

## Source

`logo.svg` is the single source of truth. Everything else is generated from it.

## Generate

```bash
python3 branding/generate_assets.py
```

Requires: `rsvg-convert` (`brew install librsvg`) and `Pillow` (`pip3 install pillow`).

## Files

```
branding/
├── logo.svg               ← edit this
├── generate_assets.py     ← run to regenerate
├── BRANDING.md
└── assets/
    ├── logo.svg           ← copy of source
    ├── logo-512.png       ← rasterized
    └── favicon.ico        ← multi-size ico
```

## Where they go

| Asset | Destination | Used by |
|-------|-------------|---------|
| `logo.svg` | `website/assets/logo.svg` | Nav bar, og image |
| `logo-512.png` | `website/assets/logo.png` | Fallback |
| `favicon.ico` | `website/favicon.ico` | Browser tab |

## Colors

| Hex | Usage |
|-----|-------|
| `#1E90FF` | Gradient start (blue) |
| `#6C5CE7` | Gradient end (purple) |
| `#2563EB` | Resize mark top-left |
| `#7C3AED` | Resize mark bottom-right |
