# ARKitRoomScanner

An iOS app that uses ARKit's LiDAR scene reconstruction to scan a room and export the result as a structured ZIP archive — mesh, classified faces, and RGB frames with camera poses.

## Features

- Real-time LiDAR mesh reconstruction with face classification (wall / floor / ceiling / table / seat / window / door)
- Live AR overlay: a blue sphere reveals scanned geometry as the room is mapped
- Spatially-sampled frame capture (up to 150 frames, spaced by movement and rotation thresholds)
- Interactive 3D mesh preview after scan
- One-tap export to a ZIP containing:
  - `mesh.ply` — binary PLY with vertex positions and per-face classification
  - `frames/XXXX.jpg` — JPEG images at 60% quality
  - `metadata.json` — frame count, vertex count, camera transforms (column-major 4×4) and intrinsics (3×3)

## Requirements

| Requirement | Version |
|---|---|
| iOS | 16.0+ |
| Xcode | 15.0+ |
| Device | LiDAR-equipped iPhone or iPad (iPhone 12 Pro / iPad Pro 2020 or newer) |

The app will not run on the Simulator — LiDAR and ARKit scene reconstruction require real hardware.

## Setup

> **Note:** Personal Apple ID, Team ID, and code-signing credentials have been removed from this repository. You need to add your own before building.

1. Clone the repo and open `ARKitRoomScanner.xcodeproj` in Xcode.
2. Select the `ARKitRoomScanner` target → **Signing & Capabilities**.
3. Set your **Team** and update the **Bundle Identifier** if needed (currently `cpp.ARKitRoomScanner`).
4. Connect a LiDAR device, select it as the run destination, and build.

No third-party dependencies — the project uses only Apple frameworks (ARKit, SceneKit, SwiftUI).

## Export Format

The exported ZIP has this layout:

```
scan_<timestamp>.zip
├── mesh.ply          # Binary PLY, little-endian
├── metadata.json     # Scan metadata + per-frame poses
└── frames/
    ├── 0000.jpg
    ├── 0001.jpg
    └── ...
```

### mesh.ply

Binary little-endian PLY with:
- **vertex** elements: `x y z` (float32)
- **face** elements: `vertex_indices` (list uchar int) + `classification` (uchar)

### metadata.json

```json
{
  "version": 1,
  "frame_count": 42,
  "vertex_count": 18500,
  "face_count": 12300,
  "captured_at": 1748000000.0,
  "coordinate_system": "arkit",
  "transform_layout": "column_major_16f",
  "face_classification": {
    "values": { "0": "none", "1": "wall", "2": "floor", "3": "ceiling",
                "4": "table", "5": "seat", "6": "window", "7": "door" }
  },
  "frames": [
    { "index": 0, "transform": [...16 floats...], "intrinsics": [...9 floats...] }
  ]
}
```

`transform` is a column-major 4×4 camera-to-world matrix in ARKit's right-handed coordinate system (Y up). `intrinsics` is a column-major 3×3 camera intrinsic matrix.

## Code Structure

| File | Purpose |
|---|---|
| `ARKitRoomScannerApp.swift` | App entry point |
| `ContentView.swift` | Main UI, scan controls, ZIP export |
| `ARScanSession.swift` | ARSession management, mesh accumulation, frame sampling |
| `ScanPackage.swift` | Data models (`ScanPackage`, `LightweightFrame`, `MeshClass`) |
| `MeshPreviewView.swift` | Interactive SceneKit mesh preview |

## License

MIT
