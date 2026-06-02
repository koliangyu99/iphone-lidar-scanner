# ARKit Scan Pipeline

CPU-only Python pipeline that turns a scan ZIP exported from ARKitRoomScanner into a textured 3D model and structured room data.

---

## Quick Start

```bash
# Install dependencies (one-time)
pip install -r requirements.txt

# Run on a scan ZIP
python process_scan.py /path/to/scan_<timestamp>.zip
```

Outputs land in a folder named after the ZIP (e.g. `scan_1777919885/`):

| File | Description |
|---|---|
| `room_textured.glb` | Vertex-coloured mesh (pre-alignment) — open in any GLB viewer |
| `room_tagged.glb` | Aligned mesh with red/blue spheres marking doors and windows |
| `room_white.glb` | Aligned mesh coloured by ARKit face class (wall/floor/ceiling/…) |
| `results.json` | Room dimensions (cm) and detected fixture positions |
| `scan_raw/` | Extracted ZIP contents (can be deleted after processing) |

---

## Options

```
python process_scan.py <scan.zip> [--out-dir DIR] [--room-type LABEL]
```

| Flag | Default | Description |
|---|---|---|
| `--out-dir` | Same folder as ZIP | Where to write output files |
| `--room-type` | `bedroom` | Room label written into `results.json` |

---

## Pipeline Steps

| Step | What it does |
|---|---|
| 1 | Unzip scan archive |
| 2 | Read `mesh.ply` — vertices, faces, per-face ARKit classification |
| 3 | Compute vertex normals (via trimesh) |
| 4 | Parse `metadata.json` — camera extrinsics + intrinsics per frame |
| 5 | Project each camera frame onto mesh vertices (angle + distance weighted) |
| 6 | Fill small holes (boundary loop tracing + fan triangulation) |
| 7 | Export pre-alignment textured GLB |
| 8 | Align coordinates — SVD on wall normals → floor at y=0, room corner at origin |
| 9 | Extract fixtures — connected components on door/window faces, bounding box fit |
| 10 | Write `results.json` |
| 11 | Export tagged GLB with coloured fixture spheres |
| 12 | Export class-coloured white mesh GLB |

---

## results.json Format

```json
{
  "room": {
    "type": "bedroom",
    "dimensions": {
      "width":  380.5,
      "length": 420.0,
      "height": 245.3
    }
  },
  "fixtures": [
    {
      "type": "door",
      "wall": "left",
      "position":   { "x": 0.0, "y": 5.0, "z": 120.0 },
      "dimensions": { "width": 90.0, "height": 205.0 },
      "is_primary": true
    }
  ]
}
```

All dimensions and positions are in **centimetres**, in the aligned coordinate system (floor at y=0).

---

## Tuning Parameters

Edit the constants near the top of `process_scan.py`:

| Parameter | Default | Description |
|---|---|---|
| `MAX_HOLE_AREA` | `0.05 m²` | Holes larger than this are left open |
| `MIN_DOOR_FACES` | `30` | Minimum faces for a door component |
| `MIN_DOOR_W / H` | `40 / 80 cm` | Minimum door dimensions |
| `MIN_WIN_FACES` | `30` | Minimum faces for a window component |
| `MIN_WIN_W / H` | `30 / 30 cm` | Minimum window dimensions |
| `BALL_RADIUS` | `0.15 m` | Fixture marker sphere size in tagged GLB |

---

## Dependencies

```
trimesh[easy]   – mesh I/O, hole fill, GLB export, vertex normals
plyfile         – read binary PLY from ARKit
Pillow          – load JPEG camera frames
numpy           – all numerical operations
```

Install with:

```bash
pip install -r requirements.txt
```
