//
//  ContentView.swift
//  ARKitRoomScanner
//
//  Created by Roy on 2026/3/30.
//
import SwiftUI
import ARKit
import SceneKit
import Compression

struct ContentView: View {

    @StateObject private var scanner = ARScanSession()

    @State private var scanPackage:  ScanPackage?
    @State private var showPreview:  Bool = false
    @State private var isSharing:    Bool = false
    @State private var shareFileURL: URL?
    @State private var isExporting:  Bool = false

    var body: some View {
        ZStack {

            // ── AR camera underneath ──────────────
            ARViewContainer(session: scanner.session,
                            isScanning: scanner.isScanning)
                .ignoresSafeArea()

            // ── Overlay UI ────────────────────────
            VStack {
                Spacer()
                statusPill
                actionButtons
                    .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)

            // ── Mesh preview sheet ────────────────
            if showPreview, let pkg = scanPackage {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Text("Room Scan")
                        .font(.headline)
                        .foregroundColor(.white)

                    MeshPreviewView(package: pkg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 400)
                        .cornerRadius(16)

                    // Stats
                    HStack(spacing: 20) {
                        Label(
                            "\(pkg.vertices.count) verts",
                            systemImage: "cube"
                        )
                        Label(
                            "\(pkg.frames.count) frames",
                            systemImage: "camera"
                        )
                    }
                    .font(.caption)
                    .foregroundColor(.gray)

                    HStack(spacing: 16) {
                        // Share button
                        Button {
                            Task {
                                await exportAndShare(pkg)
                            }
                        } label: {
                            if isExporting {
                                HStack {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Packing...")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Label(
                                    "Share ZIP",
                                    systemImage: "square.and.arrow.up"
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isExporting)

                        // Rescan button
                        Button {
                            showPreview = false
                            scanPackage = nil
                            scanner.reset()
                        } label: {
                            Label(
                                "Rescan",
                                systemImage: "arrow.counterclockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(isExporting)
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
        }
        .sheet(isPresented: $isSharing) {
            if let url = shareFileURL {
                ShareSheet(items: [url])
            }
        }
    }

    // ── Status pill ───────────────────────────────

    @ViewBuilder
    var statusPill: some View {
        if scanner.isScanning {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Scanning — \(scanner.frameCount) / 150 frames")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .padding(.bottom, 12)

        } else if scanner.scanComplete {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Scan complete!")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .padding(.bottom, 12)

        } else {
            Text("Point at your room and tap Start")
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .padding(.bottom, 12)
        }
    }

    // ── Action buttons ────────────────────────────

    @ViewBuilder
    var actionButtons: some View {
        if !scanner.isScanning && !scanner.scanComplete {
            Button {
                scanner.startScan()
            } label: {
                Label("Start Scan", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)

        } else if scanner.isScanning {
            Button {
                let pkg     = scanner.stopScan()
                scanPackage = pkg
                showPreview = true
            } label: {
                Label("Stop & Preview", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

        } else if scanPackage != nil {
            Button {
                showPreview = true
            } label: {
                Label("View Scan", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
        }
    }

    // ── Export + Share ────────────────────────────

    @MainActor
    func exportAndShare(_ package: ScanPackage) async {
        isExporting = true
        defer { isExporting = false }

        do {
            let zipURL = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.buildZip(package)
            }.value

            shareFileURL = zipURL
            isSharing    = true

        } catch {
            print("Export error: \(error)")
        }
    }

    // ── Build ZIP (runs off main thread) ──────────

    static func buildZip(_ package: ScanPackage) throws -> URL {

        let ts      = Int(Date().timeIntervalSince1970)
        let tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("scan_\(ts)", isDirectory: true)
        let framesDir = tempDir
            .appendingPathComponent("frames", isDirectory: true)

        // Clean + create folders
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default
            .createDirectory(at: framesDir,
                           withIntermediateDirectories: true)

        // ── 1. Write mesh.ply ──────────────────────
        let plyURL = tempDir.appendingPathComponent("mesh.ply")
        try writePLY(package: package, to: plyURL)

        // ── 2. Write frames + build metadata ───────
        var framesMeta: [[String: Any]] = []

        for (i, frame) in package.frames.enumerated() {
            // Save JPEG file
            let imgURL = framesDir
                .appendingPathComponent(
                    String(format: "%04d.jpg", i)
                )
            try frame.imageJpeg.write(to: imgURL)

            // Store pose metadata (no image bytes here)
            framesMeta.append([
                "index":      i,
                "transform":  frame.transform,   // [Float] 16
                "intrinsics": frame.intrinsics   // [Float] 9
            ])
        }

        // ── 3. Write metadata.json ─────────────────
        let meta: [String: Any] = [
            "version":      1,
            "frame_count":  package.frames.count,
            "vertex_count": package.vertices.count,
            "face_count":   package.faces.count / 3,
            "captured_at":  package.capturedAt
                                .timeIntervalSince1970,
            "coordinate_system": "arkit",
            "transform_layout": "column_major_16f",
            "face_classification": [
                "property": "classification",
                "values": [
                    "0": "none",
                    "1": "wall",
                    "2": "floor",
                    "3": "ceiling",
                    "4": "table",
                    "5": "seat",
                    "6": "window",
                    "7": "door"
                ]
            ],
            "frames": framesMeta
        ]

        let metaData = try JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        )
        let metaURL = tempDir
            .appendingPathComponent("metadata.json")
        try metaData.write(to: metaURL)

        // ── 4. ZIP the folder ──────────────────────
        let zipURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("scan_\(ts).zip")

        try? FileManager.default.removeItem(at: zipURL)
        try zipFolder(at: tempDir, to: zipURL)

        // Cleanup temp folder
        try? FileManager.default.removeItem(at: tempDir)

        return zipURL
    }

    // ── Write binary PLY ──────────────────────────
    // Binary is much faster + smaller than ASCII

    static func writePLY(
        package: ScanPackage,
        to url: URL) throws {

        var data = Data()

        let vertCount = package.vertices.count
        let faceCount = package.faces.count / 3

        // Header (ASCII)
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(vertCount)
        property float x
        property float y
        property float z
        element face \(faceCount)
        property list uchar int vertex_indices
        property uchar classification
        end_header\n
        """
        data.append(header.data(using: .utf8)!)

        // Vertices (binary float32)
        for v in package.vertices {
            var x = v[0], y = v[1], z = v[2]
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
        }

        // Faces (binary: uchar count + 3× int32 + uchar classification)
        for i in 0..<faceCount {
            var count: UInt8 = 3
            var a = Int32(package.faces[i * 3])
            var b = Int32(package.faces[i * 3 + 1])
            var c = Int32(package.faces[i * 3 + 2])
            var cls = i < package.faceClassifications.count
                ? package.faceClassifications[i]
                : UInt8(0)
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &a)     { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &b)     { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &c)     { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &cls)   { data.append(contentsOf: $0) }
        }

        try data.write(to: url)
    }

    // ── ZIP folder using NSFileCoordinator ─────────

    static func zipFolder(
        at sourceURL: URL,
        to destURL: URL) throws {

        var coordinatorError: NSError?
        var zipError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .forUploading,
            error: &coordinatorError
        ) { zippedURL in
            do {
                try FileManager.default
                    .copyItem(at: zippedURL, to: destURL)
            } catch {
                zipError = error
            }
        }

        if let e = coordinatorError { throw e }
        if let e = zipError         { throw e }
    }
}

// ── AR view wrapper ───────────────────────────────

struct ARViewContainer: UIViewRepresentable {
    let session:   ARSession
    let isScanning: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session  = session
        view.delegate = context.coordinator
        view.autoenablesDefaultLighting = true
        view.debugOptions = []
        context.coordinator.setupBlueSphere(in: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.blueSphereNode?.isHidden = !isScanning
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, ARSCNViewDelegate {

        var meshNodes:      [UUID: SCNNode] = [:]
        var updateCounts:   [UUID: Int]     = [:]
        var blueSphereNode: SCNNode?

        // Large sphere centred on world origin — its inner surface
        // covers the entire FOV in blue until occluders peel it away.
        func setupBlueSphere(in view: ARSCNView) {
            let sphere = SCNSphere(radius: 100)
            sphere.segmentCount = 12

            let mat = SCNMaterial()
            mat.diffuse.contents    = UIColor(red: 0.1, green: 0.45,
                                              blue: 1.0, alpha: 0.55)
            mat.lightingModel       = .constant
            mat.isDoubleSided       = true   // visible from inside
            mat.writesToDepthBuffer = false  // doesn't block occluders
            sphere.materials = [mat]

            let node = SCNNode(geometry: sphere)
            node.renderingOrder = 1          // renders after occluders
            node.isHidden = true
            blueSphereNode = node
            view.scene.rootNode.addChildNode(node)
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didAdd node: SCNNode,
                      for anchor: ARAnchor) {
            guard anchor is ARMeshAnchor else { return }
            updateCounts[anchor.identifier] = 0
            // No visual node yet — blue sphere covers this area
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode,
                      for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            let count = (updateCounts[anchor.identifier] ?? 0) + 1
            updateCounts[anchor.identifier] = count

            meshNodes[anchor.identifier]?.removeFromParentNode()
            meshNodes.removeValue(forKey: anchor.identifier)

            // Wait for a few updates before treating area as scanned
            guard count >= 3 else { return }

            let meshNode = buildScannedNode(meshAnchor)
            node.addChildNode(meshNode)
            meshNodes[anchor.identifier] = meshNode
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didRemove node: SCNNode,
                      for anchor: ARAnchor) {
            meshNodes[anchor.identifier]?.removeFromParentNode()
            meshNodes.removeValue(forKey: anchor.identifier)
            updateCounts.removeValue(forKey: anchor.identifier)
        }

        // Builds two child nodes per anchor:
        //   1. Occluder  — invisible triangles that write to the depth
        //      buffer, causing the blue sphere to fail depth test there
        //      and reveal the real camera feed behind it.
        //   2. Wireframe — green lines drawn on top of the occluder.
        private func buildScannedNode(_ anchor: ARMeshAnchor) -> SCNNode {

            let geo = anchor.geometry

            // Copy Metal buffer contents into Swift-owned memory immediately.
            // ARKit can reallocate the MTLBuffer at any time; holding a raw
            // pointer past the current call risks EXC_BAD_ACCESS.
            let vCount  = geo.vertices.count
            let vStride = geo.vertices.stride
            let vRaw    = Data(bytes: geo.vertices.buffer.contents(),
                               count: vCount * vStride)

            let fCount  = geo.faces.count
            let fRaw    = Data(bytes: geo.faces.buffer.contents(),
                               count: fCount * 3 * MemoryLayout<UInt32>.size)

            var vertices: [SCNVector3] = []
            vertices.reserveCapacity(vCount)
            vRaw.withUnsafeBytes { buf in
                for i in 0..<vCount {
                    let v = buf.baseAddress!
                        .advanced(by: i * vStride)
                        .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    vertices.append(SCNVector3(v.x, v.y, v.z))
                }
            }
            let vertexSource = SCNGeometrySource(vertices: vertices)

            var indices: [UInt32] = []
            indices.reserveCapacity(fCount * 3)
            fRaw.withUnsafeBytes { buf in
                for i in 0..<(fCount * 3) {
                    indices.append(buf.baseAddress!
                        .advanced(by: i * MemoryLayout<UInt32>.size)
                        .assumingMemoryBound(to: UInt32.self).pointee)
                }
            }

            // ── 1. Occluder (depth write, no colour) ──────
            let fillData = Data(bytes: indices,
                                count: indices.count * MemoryLayout<UInt32>.size)
            let fillElement = SCNGeometryElement(
                data:           fillData,
                primitiveType:  .triangles,
                primitiveCount: fCount,
                bytesPerIndex:  MemoryLayout<UInt32>.size
            )
            let occluderGeo = SCNGeometry(sources: [vertexSource],
                                          elements: [fillElement])
            let occluderMat = SCNMaterial()
            occluderMat.colorBufferWriteMask = []   // write nothing to colour
            occluderMat.writesToDepthBuffer  = true
            occluderMat.readsFromDepthBuffer = true
            occluderGeo.materials = [occluderMat]
            let occluderNode = SCNNode(geometry: occluderGeo)
            occluderNode.renderingOrder = 0         // renders before blue sphere

            // ── 2. Green wireframe ─────────────────────────
            var lineIndices: [UInt32] = []
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = indices[i], b = indices[i+1], c = indices[i+2]
                lineIndices.append(contentsOf: [a, b, b, c, c, a])
            }
            let lineData = Data(bytes: lineIndices,
                                count: lineIndices.count * MemoryLayout<UInt32>.size)
            let wireElement = SCNGeometryElement(
                data:           lineData,
                primitiveType:  .line,
                primitiveCount: lineIndices.count / 2,
                bytesPerIndex:  MemoryLayout<UInt32>.size
            )
            let wireGeo = SCNGeometry(sources: [vertexSource],
                                      elements: [wireElement])
            let wireMat = SCNMaterial()
            wireMat.diffuse.contents     = UIColor(red: 0.0, green: 1.0,
                                                   blue: 0.4, alpha: 1.0)
            wireMat.lightingModel        = .constant
            wireMat.isDoubleSided        = true
            wireMat.writesToDepthBuffer  = false
            wireMat.readsFromDepthBuffer = false    // always on top
            wireGeo.materials = [wireMat]
            let wireNode = SCNNode(geometry: wireGeo)
            wireNode.renderingOrder = 3             // renders after blue sphere

            let container = SCNNode()
            container.addChildNode(occluderNode)
            container.addChildNode(wireNode)
            return container
        }
    }
}

// ── System share sheet wrapper ────────────────────

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ vc: UIActivityViewController,
        context: Context) {}
}
