# ARKitRoomScanner

**Turn any iPhone Pro into a 3D scanner — point, scan, done.**

No special hardware. No cloud upload. Just the LiDAR sensor already in your pocket, scanning rooms, offices, buildings, corridors, or outdoor spaces in seconds.

---

## Demo

<!-- Drop assets/demo_realtime.gif here (phone screen recording) -->
<p align="center">
  <img src="assets/demo_realtime.gif" width="320" alt="Real-time LiDAR scan on iPhone Pro"/>
</p>

<br>

<!-- Drop assets/demo_white_mesh.gif and assets/demo_textured_mesh.gif here -->
<!-- They sit side by side so viewers can compare classified vs. textured output -->
<table align="center">
  <tr>
    <th align="center">Classified Mesh</th>
    <th align="center">Textured Mesh</th>
  </tr>
  <tr>
    <td align="center">
      <img src="assets/demo_white_mesh.gif" width="100%" alt="ARKit classified mesh rotating"/>
    </td>
    <td align="center">
      <img src="assets/demo_textured_mesh.gif" width="100%" alt="Photo-textured mesh rotating"/>
    </td>
  </tr>
</table>

---

## What is this?

Most 3D scanning tools require a dedicated scanner, a DSLR rig, or an expensive subscription service.

ARKitRoomScanner uses the **LiDAR sensor built into every iPhone Pro and iPad Pro** to capture a precise, semantically labelled 3D mesh of any space — indoors or out. Walk through a room, circle a building, drive down a corridor. Tap **Stop**, and you have a structured dataset ready for any downstream use.

The companion **Python pipeline** processes the exported ZIP on any laptop (CPU only, no GPU needed) and produces:

- A photo-textured 3D model (`.glb`) you can open in any viewer
- A class-coloured mesh showing walls, floors, ceilings, tables, doors, and windows
- A `results.json` with room dimensions and detected fixture positions

**Use cases:** interior design, architecture, construction, robotics mapping, AR content creation, spatial AI training data.

---

## Features

- **Real-time LiDAR reconstruction** with ARKit's per-face semantic labels (wall / floor / ceiling / table / seat / window / door)
- **Live AR overlay** — a blue sphere reveals scanned geometry as the room fills in
- **Smart frame sampling** — up to 150 spatially distributed frames, gated by movement and rotation thresholds so you never capture redundant data
- **Interactive 3D preview** on-device before export
- **One-tap ZIP export** via the iOS share sheet — AirDrop to your Mac in seconds
- **Python pipeline** (CPU-only): vertex colouring, hole filling, coordinate alignment, fixture extraction, and structured JSON output

---

## Requirements

### iOS App

| | |
|---|---|
| iOS | 16.0+ |
| Xcode | 15.0+ |
| Device | LiDAR iPhone or iPad — iPhone 12 Pro / iPad Pro 2020 or newer |

> The app requires real hardware. LiDAR and ARKit scene reconstruction do not work in the Simulator.

### Python Pipeline

| | |
|---|---|
| Python | 3.9+ |
| OS | macOS / Linux / Windows |
| Hardware | Any CPU — no GPU required |

---

## Setup

### iOS App

1. Clone the repo and open `ARKitRoomScanner.xcodeproj` in Xcode.
2. Select the `ARKitRoomScanner` target → **Signing & Capabilities**.
3. Set your **Team** and update the **Bundle Identifier** if needed.
4. Connect your LiDAR device, select it as the run destination, and build.

No third-party Swift dependencies — only Apple frameworks (ARKit, SceneKit, SwiftUI).

### Python Pipeline

```bash
# Install dependencies (one-time)
pip install -r pipeline/requirements.txt

# Process a scan ZIP
python pipeline/process_scan.py /path/to/scan_<timestamp>.zip

# Optional flags
python pipeline/process_scan.py scan.zip --out-dir ~/Desktop/output --room-type living_room
```

See [`pipeline/README.md`](pipeline/README.md) for full pipeline documentation.

---

## Export Format

The iOS app exports a ZIP with this layout:

```
scan_<timestamp>.zip
├── mesh.ply          # Binary PLY — vertex positions + per-face classification
├── metadata.json     # Frame count, vertex count, camera poses + intrinsics
└── frames/
    ├── 0000.jpg
    ├── 0001.jpg
    └── ...
```

`metadata.json` stores each frame's **column-major 4×4 camera-to-world transform** and **3×3 intrinsic matrix** in ARKit's right-handed coordinate system (Y up).

---

## License

MIT
