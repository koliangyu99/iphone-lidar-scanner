//
//  ARScanSession.swift
//  ARKitRoomScanner
//
//  Created by Roy on 2026/3/30.
//

import ARKit
import Combine

class ARScanSession: NSObject,
                     ObservableObject,
                     ARSessionDelegate {

    let session = ARSession()

    @Published var frameCount:   Int  = 0
    @Published var isScanning:   Bool = false
    @Published var scanComplete: Bool = false

    private var meshAnchors:    [UUID: ARMeshAnchor] = [:]
    private var capturedFrames: [LightweightFrame]   = []

    private var lastCapturePosition = SIMD3<Float>.zero
    private var lastCaptureRotation = simd_quatf(
        ix: 0, iy: 0, iz: 0, r: 1)

    private let minMoveDist: Float = 0.15
    private let minAngle:    Float = 0.20
    private let maxFrames:   Int   = 150

    override init() {
        super.init()
        session.delegate = self
    }

    // ── Public ─────────────────────────────────────

    func startScan() {
        guard ARWorldTrackingConfiguration
            .supportsSceneReconstruction(.meshWithClassification) else {
            print("⚠️ LiDAR not supported on this device")
            return
        }

        meshAnchors    = [:]
        capturedFrames = []

        DispatchQueue.main.async {
            self.frameCount   = 0
            self.isScanning   = true
            self.scanComplete = false
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification

        session.run(
            config,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    func stopScan() -> ScanPackage {
        session.pause()

        DispatchQueue.main.async {
            self.isScanning   = false
            self.scanComplete = true
        }

        return buildPackage()
    }

    func reset() {
        meshAnchors    = [:]
        capturedFrames = []

        DispatchQueue.main.async {
            self.frameCount   = 0
            self.isScanning   = false
            self.scanComplete = false
        }
    }

    // ── ARSessionDelegate ──────────────────────────

    func session(_ session: ARSession,
                 didUpdate frame: ARFrame) {
        guard isScanning else { return }
        guard capturedFrames.count < maxFrames else { return }

        let pos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let rot = simd_quaternion(frame.camera.transform)

        let moved   = simd_distance(pos, lastCapturePosition)
        let rotated = angleBetween(lastCaptureRotation, rot)

        guard moved > minMoveDist || rotated > minAngle else {
            return
        }

        autoreleasepool {
            let lf = LightweightFrame(from: frame)
            DispatchQueue.main.async {
                self.capturedFrames.append(lf)
                self.frameCount = self.capturedFrames.count
            }
        }

        lastCapturePosition = pos
        lastCaptureRotation = rot
    }

    func session(_ session: ARSession,
                 didAdd anchors: [ARAnchor]) {
        storeMeshAnchors(anchors)
    }

    func session(_ session: ARSession,
                 didUpdate anchors: [ARAnchor]) {
        storeMeshAnchors(anchors)
    }

    // ── Private helpers ────────────────────────────

    private func storeMeshAnchors(_ anchors: [ARAnchor]) {
        for anchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            meshAnchors[anchor.identifier] = anchor
        }
    }

    private func buildPackage() -> ScanPackage {
        var allVertices:            [[Float]] = []
        var allFaces:               [UInt32]  = []
        var allFaceClassifications: [UInt8]   = []
        var vertexOffset:           UInt32    = 0

        for anchor in meshAnchors.values {
            let geo = anchor.geometry

            let vBuf    = geo.vertices.buffer.contents()
            let vStride = geo.vertices.stride
            let vCount  = geo.vertices.count

            for i in 0..<vCount {
                let ptr = vBuf
                    .advanced(by: i * vStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let local = ptr.pointee
                let world = anchor.transform * SIMD4<Float>(
                    local.x, local.y, local.z, 1.0
                )
                allVertices.append([world.x, world.y, world.z])
            }

            let fBuf   = geo.faces.buffer.contents()
            let fCount = geo.faces.count

            for i in 0..<(fCount * 3) {
                let ptr = fBuf
                    .advanced(by: i * MemoryLayout<UInt32>.size)
                    .assumingMemoryBound(to: UInt32.self)
                allFaces.append(ptr.pointee + vertexOffset)
            }

            // One classification byte per face triangle
            if let classification = geo.classification {
                let cBuf    = classification.buffer.contents()
                let cStride = classification.stride
                for i in 0..<fCount {
                    let ptr = cBuf
                        .advanced(by: i * cStride)
                        .assumingMemoryBound(to: UInt8.self)
                    allFaceClassifications.append(ptr.pointee)
                }
            } else {
                allFaceClassifications.append(contentsOf: [UInt8](repeating: 0, count: fCount))
            }

            vertexOffset += UInt32(vCount)
        }

        return ScanPackage(
            vertices:            allVertices,
            faces:               allFaces,
            faceClassifications: allFaceClassifications,
            frames:              capturedFrames
        )
    }

    private func angleBetween(
        _ a: simd_quatf,
        _ b: simd_quatf) -> Float {
        let d = abs(simd_dot(a, b))
        return 2.0 * acos(min(d, 1.0))
    }
}


