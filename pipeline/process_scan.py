"""
ARKit Room Scan Pipeline  (local CPU version)

Usage:
    python process_scan.py <scan.zip> [options]

Options:
    --out-dir   Directory for output files  (default: same folder as the ZIP)
    --room-type Room label written into results.json  (default: bedroom)

Outputs:
    room_textured.glb   Vertex-coloured mesh before alignment
    room_tagged.glb     Aligned mesh + coloured fixture spheres
    room_white.glb      Aligned mesh coloured by ARKit face class
    results.json        Room dimensions + fixture list
"""

import argparse
import json
import time
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image as PILImage
from plyfile import PlyData

# ── Config defaults (overridable via CLI or by editing here) ─────────────────

BALL_RADIUS   = 0.15   # metres – fixture marker sphere size
MAX_HOLE_AREA = 0.05   # m² – holes larger than this are left open

MIN_DOOR_FACES = 30
MIN_DOOR_W     = 40    # cm
MIN_DOOR_H     = 80    # cm
MIN_WIN_FACES  = 30
MIN_WIN_W      = 30    # cm
MIN_WIN_H      = 30    # cm

LABELS = ['none', 'wall', 'floor', 'ceiling', 'table', 'seat', 'window', 'door']

COLOR_MAP = {
    0: [255, 255, 255, 255],   # none    – white
    1: [180, 180, 200, 200],   # wall    – grey
    2: [120, 180, 120, 200],   # floor   – green
    3: [200, 200, 240, 200],   # ceiling – light blue
    4: [210, 140,  60, 220],   # table   – orange
    5: [180,  80,  80, 220],   # seat    – red
    6: [100, 200, 240, 220],   # window  – cyan
    7: [240, 200,  60, 220],   # door    – yellow
}

FIXTURE_COLORS = {
    'door':   [255,  60,  60, 255],   # red
    'window': [ 60, 120, 255, 255],   # blue
}

# ── Helpers ──────────────────────────────────────────────────────────────────

def parse_transform(t16):
    return np.array(t16, dtype=np.float64).reshape(4, 4).T


def parse_intrinsics(k9):
    return np.array(k9, dtype=np.float64).reshape(3, 3).T


def compute_face_normals(v, f):
    v0 = v[f[:, 0]]; v1 = v[f[:, 1]]; v2 = v[f[:, 2]]
    n   = np.cross(v1 - v0, v2 - v0)
    mag = np.linalg.norm(n, axis=1, keepdims=True)
    return n / (mag + 1e-8)


def loop_area_2d(loop_pts):
    pts  = loop_pts[:, [0, 2]]   # XZ plane
    n    = len(pts)
    area = 0.0
    for i in range(n):
        j = (i + 1) % n
        area += pts[i, 0] * pts[j, 1] - pts[j, 0] * pts[i, 1]
    return abs(area) / 2.0


def connected_components(faces, face_indices):
    n = len(face_indices)
    if n == 0:
        return []
    sub_faces     = faces[face_indices]
    edge_to_local = defaultdict(list)
    for li, face in enumerate(sub_faces):
        for j in range(3):
            edge = tuple(sorted([int(face[j]), int(face[(j + 1) % 3])]))
            edge_to_local[edge].append(li)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x

    def union(a, b):
        pa, pb = find(a), find(b)
        if pa != pb:
            parent[pa] = pb

    for fs in edge_to_local.values():
        for i in range(1, len(fs)):
            union(fs[0], fs[i])
    groups = defaultdict(list)
    for li in range(n):
        groups[find(li)].append(face_indices[li])
    return sorted(groups.values(), key=len, reverse=True)


def identify_wall(centroid, x_max, z_max):
    cx, cz = centroid[0], centroid[2]
    dists  = {'left': cx, 'right': x_max - cx,
               'bottom': cz, 'top': z_max - cz}
    return min(dists, key=dists.get)


def fit_fixture(comp_indices, verts_a, faces, x_max, z_max, ftype):
    pts      = verts_a[faces[comp_indices].flatten()]
    centroid = pts.mean(axis=0)
    wall     = identify_wall(centroid, x_max, z_max)
    if wall in ('left', 'right'):
        u, v = pts[:, 2], pts[:, 1]
    else:
        u, v = pts[:, 0], pts[:, 1]
    u_min, u_max = u.min(), u.max()
    v_min, v_max = v.min(), v.max()
    width  = round((u_max - u_min) * 100, 3)
    height = round((v_max - v_min) * 100, 3)
    pos_u  = (u_min + u_max) / 2
    pos_v  = v_min
    if wall in ('left', 'right'):
        wall_x = 0.0 if wall == 'left' else x_max
        pos = [round(wall_x * 100, 3), round(pos_v * 100, 3), round(pos_u * 100, 3)]
    else:
        wall_z = 0.0 if wall == 'bottom' else z_max
        pos = [round(pos_u * 100, 3), round(pos_v * 100, 3), round(wall_z * 100, 3)]
    return {
        'type': ftype, 'wall': wall,
        'position':   {'x': pos[0], 'y': pos[1], 'z': pos[2]},
        'dimensions': {'width': width, 'height': height},
        'is_primary': False,
        '_centroid':  centroid.tolist(),
    }


# ── Main pipeline ────────────────────────────────────────────────────────────

def run(scan_zip: Path, out_dir: Path, room_type: str):
    out_dir.mkdir(parents=True, exist_ok=True)

    out_glb        = out_dir / 'room_textured.glb'
    out_json       = out_dir / 'results.json'
    out_tagged_glb = out_dir / 'room_tagged.glb'
    out_white_glb  = out_dir / 'room_white.glb'

    # ── Step 1: Unzip ────────────────────────────────────────────────────────
    raw_dir = out_dir / 'scan_raw'
    raw_dir.mkdir(exist_ok=True)

    print('Extracting ZIP...')
    with zipfile.ZipFile(scan_zip, 'r') as z:
        z.extractall(raw_dir)

    scan_dirs = [p for p in raw_dir.iterdir() if p.is_dir()]
    scan_dir  = scan_dirs[0]
    ply_path   = scan_dir / 'mesh.ply'
    meta_path  = scan_dir / 'metadata.json'
    frames_dir = scan_dir / 'frames'
    print(f'Scan dir: {scan_dir.name}')

    # ── Step 2: Read PLY ─────────────────────────────────────────────────────
    plydata     = PlyData.read(str(ply_path))
    vertex_data = plydata['vertex']
    face_data   = plydata['face']

    verts = np.stack([
        vertex_data['x'], vertex_data['y'], vertex_data['z']
    ], axis=1).astype(np.float64)

    faces = np.array(
        [f.tolist() for f in face_data['vertex_indices']], dtype=np.int32
    )

    prop_names = [p.name for p in face_data.properties]
    if 'classification' in prop_names:
        face_classes = np.array(face_data['classification'], dtype=np.uint8)
    else:
        face_classes = np.zeros(len(faces), dtype=np.uint8)

    counts = np.bincount(face_classes, minlength=8)
    print(f'Vertices: {len(verts):,}   Faces: {len(faces):,}')
    for lbl, cnt in zip(LABELS, counts):
        if cnt > 0:
            print(f'  {lbl:10s}: {cnt:,} faces')

    # ── Step 3: Vertex normals via trimesh (CPU, no open3d needed) ───────────
    tmp_mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=False)
    norms    = np.array(tmp_mesh.vertex_normals)

    # ── Step 4: Parse metadata ───────────────────────────────────────────────
    meta        = json.loads(meta_path.read_text())
    frames_meta = meta['frames']
    N           = len(frames_meta)

    extrinsics, intrinsics, image_paths = [], [], []
    for frm in frames_meta:
        idx = frm['index']
        extrinsics.append(parse_transform(frm['transform']))
        intrinsics.append(parse_intrinsics(frm['intrinsics']))
        image_paths.append(frames_dir / f'{idx:04d}.jpg')

    extrinsics = np.stack(extrinsics)
    intrinsics = np.stack(intrinsics)

    img0 = PILImage.open(image_paths[0])
    W, H = img0.size
    print(f'Image: {W}x{H}   Frames: {N}')

    # ── Step 5: Project camera frames → vertex colours (Y-flip) ─────────────
    print('Colouring vertices...')
    colors  = np.zeros((len(verts), 3), dtype=np.float64)
    weights = np.zeros(len(verts),      dtype=np.float64)

    ones  = np.ones((len(verts), 1))
    v_hom = np.hstack([verts, ones])
    t0    = time.time()

    for cam_i in range(N):
        T       = extrinsics[cam_i]
        K       = intrinsics[cam_i]
        T_inv_i = np.linalg.inv(T)
        fx_i    = K[0, 0]; fy_i = K[1, 1]
        cx_i    = K[0, 2]; cy_i = K[1, 2]

        v_cam_i = (T_inv_i @ v_hom.T).T[:, :3]
        front_i = v_cam_i[:, 2] < 0
        zc_i    = np.where(front_i, -v_cam_i[:, 2], 1.0)

        px_i = (fx_i *  v_cam_i[:, 0]  / zc_i + cx_i).astype(int)
        py_i = (fy_i * (-v_cam_i[:, 1]) / zc_i + cy_i).astype(int)

        in_i = (front_i &
                (px_i >= 0) & (px_i < W) &
                (py_i >= 0) & (py_i < H))

        if in_i.sum() == 0:
            continue

        img_i     = np.array(PILImage.open(image_paths[cam_i])) / 255.0
        cam_pos_i = T[:3, 3]
        to_cam    = cam_pos_i - verts
        to_cam_n  = to_cam / (np.linalg.norm(to_cam, axis=1, keepdims=True) + 1e-8)
        angle_w   = np.einsum('ij,ij->i', norms, to_cam_n)
        angle_w   = np.maximum(angle_w, 0)
        dist_w    = 1.0 / (np.linalg.norm(to_cam, axis=1) + 0.001)
        weight    = angle_w * dist_w
        valid     = in_i & (weight > 0.001)

        if valid.sum() == 0:
            continue

        colors[valid]  += img_i[py_i[valid], px_i[valid]] * weight[valid, None]
        weights[valid] += weight[valid]

        if cam_i % 10 == 0:
            elapsed = time.time() - t0
            print(f'  Frame {cam_i}/{N} | {elapsed:.1f}s | '
                  f'coloured: {(weights > 0).sum():,}')

    mask          = weights > 0
    colors[mask] /= weights[mask, None]
    colors        = np.clip(colors, 0, 1)
    colors[~mask] = 0.5   # grey for uncoloured vertices

    print(f'\nColoured: {mask.sum():,}/{len(verts):,} ({100*mask.sum()/len(verts):.1f}%)')

    # ── Step 6: Hole fill ────────────────────────────────────────────────────
    print('Finding boundary loops...')
    edge_count = defaultdict(int)
    for face in faces:
        for i in range(3):
            edge = tuple(sorted([int(face[i]), int(face[(i + 1) % 3])]))
            edge_count[edge] += 1

    boundary_adj = defaultdict(list)
    for e, c in edge_count.items():
        if c == 1:
            boundary_adj[e[0]].append(e[1])
            boundary_adj[e[1]].append(e[0])

    visited = set()
    loops   = []
    for start in boundary_adj:
        if start in visited:
            continue
        loop = [start]; visited.add(start); current = start
        while True:
            neighbors = [n for n in boundary_adj[current] if n not in visited]
            if not neighbors:
                break
            nxt = neighbors[0]; visited.add(nxt)
            loop.append(nxt); current = nxt
        if len(loop) >= 3:
            loops.append(loop)

    print(f'Boundary loops found: {len(loops)}')

    small_loops = [
        (lp, loop_area_2d(verts[np.array(lp)]))
        for lp in loops
        if loop_area_2d(verts[np.array(lp)]) < MAX_HOLE_AREA
    ]
    print(f'Holes to fill (area < {MAX_HOLE_AREA} m²): {len(small_loops)}')

    new_verts  = list(verts.copy())
    new_faces  = list(faces.copy())
    new_colors = list(colors.copy())

    for lp, _ in small_loops:
        if len(lp) < 3:
            continue
        lp_pts     = verts[np.array(lp)]
        center     = lp_pts.mean(axis=0)
        center_idx = len(new_verts)
        new_verts.append(center)
        new_colors.append(np.array([new_colors[v] for v in lp]).mean(axis=0))
        for i in range(len(lp)):
            new_faces.append([lp[i], lp[(i + 1) % len(lp)], center_idx])

    new_verts  = np.array(new_verts)
    new_faces  = np.array(new_faces)
    new_colors = np.array(new_colors)

    print(f'Vertices: {len(new_verts):,}  (+{len(new_verts) - len(verts):,})')
    print(f'Faces:    {len(new_faces):,}  (+{len(new_faces) - len(faces):,})')

    # ── Step 7: Export textured GLB (pre-alignment) ──────────────────────────
    trimesh.Trimesh(
        vertices      = new_verts,
        faces         = new_faces,
        vertex_colors = (np.clip(new_colors, 0, 1) * 255).astype(np.uint8)
    ).export(str(out_glb))
    print(f'Saved: {out_glb}  ({out_glb.stat().st_size / 1e6:.1f} MB)')

    # ── Step 8: Coordinate alignment ─────────────────────────────────────────
    face_normals = compute_face_normals(verts, faces)

    WALL = 1; FLOOR = 2; CEILING = 3
    wall_mask    = face_classes == WALL
    floor_mask   = face_classes == FLOOR
    ceiling_mask = face_classes == CEILING

    wall_n    = face_normals[wall_mask]
    horiz     = np.abs(wall_n[:, 1]) < 0.3
    wall_n_xz = wall_n[horiz][:, [0, 2]]

    if len(wall_n_xz) >= 10:
        _, _, Vt     = np.linalg.svd(wall_n_xz, full_matrices=False)
        main_dir     = Vt[0]
        angle        = np.arctan2(main_dir[1], main_dir[0])
        cos_a, sin_a = np.cos(-angle), np.sin(-angle)
        R_y = np.array([[ cos_a, 0, sin_a],
                        [ 0,     1, 0    ],
                        [-sin_a, 0, cos_a]])
        print(f'Horizontal rotation: {np.degrees(angle):.1f} deg')
    else:
        R_y = np.eye(3)
        print('Too few wall faces – skipping rotation')

    verts_aligned = (R_y @ verts.T).T

    floor_vi = faces[floor_mask].flatten()
    floor_y  = np.percentile(verts_aligned[floor_vi, 1], 5)

    room_vi  = faces[wall_mask | floor_mask | ceiling_mask].flatten()
    room_pts = verts_aligned[room_vi]
    x_offset = room_pts[:, 0].min()
    z_offset = room_pts[:, 2].min()

    verts_aligned[:, 0] -= x_offset
    verts_aligned[:, 1] -= floor_y
    verts_aligned[:, 2] -= z_offset

    new_verts_aligned = (R_y @ new_verts.T).T
    new_verts_aligned[:, 0] -= x_offset
    new_verts_aligned[:, 1] -= floor_y
    new_verts_aligned[:, 2] -= z_offset

    room_pts_a = verts_aligned[faces[wall_mask | floor_mask | ceiling_mask].flatten()]
    x_max_r = room_pts_a[:, 0].max()
    y_max_r = room_pts_a[:, 1].max()
    z_max_r = room_pts_a[:, 2].max()

    print(f'Room bounds after alignment:')
    print(f'  Width  (X): {x_max_r * 100:.1f} cm')
    print(f'  Height (Y): {y_max_r * 100:.1f} cm')
    print(f'  Length (Z): {z_max_r * 100:.1f} cm')

    # ── Step 9: Fixture extraction ───────────────────────────────────────────
    DOOR = 7; WINDOW = 6

    door_comps   = connected_components(faces, np.where(face_classes == DOOR)[0])
    window_comps = connected_components(faces, np.where(face_classes == WINDOW)[0])

    fixtures = []
    for comp in door_comps:
        if len(comp) < MIN_DOOR_FACES:
            continue
        f = fit_fixture(comp, verts_aligned, faces, x_max_r, z_max_r, 'door')
        if f['dimensions']['width'] >= MIN_DOOR_W and f['dimensions']['height'] >= MIN_DOOR_H:
            fixtures.append(f)

    for comp in window_comps:
        if len(comp) < MIN_WIN_FACES:
            continue
        f = fit_fixture(comp, verts_aligned, faces, x_max_r, z_max_r, 'window')
        if f['dimensions']['width'] >= MIN_WIN_W and f['dimensions']['height'] >= MIN_WIN_H:
            fixtures.append(f)

    door_fix = [f for f in fixtures if f['type'] == 'door']
    if door_fix:
        max(door_fix, key=lambda f: f['dimensions']['width'] * f['dimensions']['height'])['is_primary'] = True

    win_fix = [f for f in fixtures if f['type'] == 'window']
    if win_fix:
        max(win_fix, key=lambda f: f['dimensions']['width'] * f['dimensions']['height'])['is_primary'] = True

    print(f'\nFixtures: {len(fixtures)}')
    print(f'{"type":8s}  {"wall":8s}  {"width":>7s}  {"height":>7s}  primary')
    print('-' * 48)
    for f in fixtures:
        print(f"{f['type']:8s}  {f['wall']:8s}  "
              f"{f['dimensions']['width']:5.0f} cm  "
              f"{f['dimensions']['height']:5.0f} cm  "
              f"{f['is_primary']}")

    # ── Step 10: Write results.json ──────────────────────────────────────────
    json_fixtures = [
        {k: v for k, v in f.items() if k != '_centroid'}
        for f in fixtures
    ]

    results = {
        'room': {
            'type': room_type,
            'dimensions': {
                'width':  round(x_max_r * 100, 3),
                'length': round(z_max_r * 100, 3),
                'height': round(y_max_r * 100, 3),
            }
        },
        'fixtures': json_fixtures,
    }

    out_json.write_text(json.dumps(results, indent=2))
    print(f'\nSaved: {out_json}')
    print(json.dumps(results, indent=2))

    # ── Step 11: Tagged GLB (aligned mesh + coloured fixture spheres) ─────────
    base_mesh = trimesh.Trimesh(
        vertices      = new_verts_aligned,
        faces         = new_faces,
        vertex_colors = (np.clip(new_colors, 0, 1) * 255).astype(np.uint8)
    )
    parts = [base_mesh]

    for f in fixtures:
        centroid = np.array(f['_centroid'])
        color    = FIXTURE_COLORS.get(f['type'], [200, 200, 200, 255])
        ball     = trimesh.creation.icosphere(subdivisions=3, radius=BALL_RADIUS)
        ball.apply_translation(centroid)
        ball.visual.vertex_colors = np.tile(color, (len(ball.vertices), 1)).astype(np.uint8)
        parts.append(ball)

    trimesh.util.concatenate(parts).export(str(out_tagged_glb))
    print(f'Saved: {out_tagged_glb}  ({out_tagged_glb.stat().st_size / 1e6:.1f} MB)')

    # ── Step 12: White (class-coloured) mesh GLB ─────────────────────────────
    mesh_main = trimesh.Trimesh(vertices=verts_aligned, faces=faces, process=False)
    face_colors = np.array(
        [COLOR_MAP.get(int(c), [200, 200, 200, 180]) for c in face_classes],
        dtype=np.uint8
    )
    mesh_main.visual = trimesh.visual.ColorVisuals(mesh=mesh_main, face_colors=face_colors)

    scene = trimesh.Scene({'room': mesh_main})
    with open(out_white_glb, 'wb') as fh:
        fh.write(scene.export(file_type='glb'))
    print(f'Saved: {out_white_glb}  ({out_white_glb.stat().st_size / 1e6:.1f} MB)')

    print('\nDone.')


# ── Entry point ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Process an ARKit scan ZIP on a local CPU machine.'
    )
    parser.add_argument('scan_zip',  type=Path, help='Path to scan_<timestamp>.zip')
    parser.add_argument('--out-dir', type=Path, default=None,
                        help='Output directory (default: same folder as ZIP)')
    parser.add_argument('--room-type', default='bedroom',
                        help='Room label for results.json (default: bedroom)')
    args = parser.parse_args()

    scan_zip = args.scan_zip.resolve()
    if not scan_zip.exists():
        parser.error(f'File not found: {scan_zip}')

    out_dir = args.out_dir.resolve() if args.out_dir else scan_zip.parent / scan_zip.stem
    run(scan_zip, out_dir, args.room_type)


if __name__ == '__main__':
    main()
