//
//  ScanPackage.swift
//  ARKitRoomScanner
//
//  Created by Roy on 2026/3/30.
//

import ARKit

struct LightweightFrame: Codable {
    var imageJpeg:  Data
    var transform:  [Float]   // 16 floats (4x4)
    var intrinsics: [Float]   // 9 floats (3x3)

    init(from frame: ARFrame) {
        // Compress camera image to JPEG
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let context = CIContext()
        if let cgImage = context.createCGImage(
            ciImage, from: ciImage.extent) {
            self.imageJpeg = UIImage(cgImage: cgImage)
                .jpegData(compressionQuality: 0.6) ?? Data()
        } else {
            self.imageJpeg = Data()
        }

        // Flatten camera pose 4x4 → [Float]
        let t = frame.camera.transform
        self.transform = [
            t.columns.0.x, t.columns.0.y,
            t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y,
            t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y,
            t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y,
            t.columns.3.z, t.columns.3.w,
        ]

        // Flatten intrinsics 3x3 → [Float]
        let k = frame.camera.intrinsics
        self.intrinsics = [
            k.columns.0.x, k.columns.0.y, k.columns.0.z,
            k.columns.1.x, k.columns.1.y, k.columns.1.z,
            k.columns.2.x, k.columns.2.y, k.columns.2.z,
        ]
    }
}

struct ScanPackage: Codable {
    var vertices:            [[Float]]           // [[x,y,z], ...]
    var faces:               [UInt32]            // [i,j,k, i,j,k, ...]
    var faceClassifications: [UInt8]             // one per face triangle
    var frames:              [LightweightFrame]
    var capturedAt:          Date = Date()
}

// ARMeshClassification raw values
enum MeshClass: UInt8 {
    case none    = 0
    case wall    = 1
    case floor   = 2
    case ceiling = 3
    case table   = 4
    case seat    = 5
    case window  = 6
    case door    = 7
}
