//
//  MeshPreviewView.swift
//  ARKitRoomScanner
//
//  Created by Roy on 2026/3/30.
//

import SwiftUI
import SceneKit

struct MeshPreviewView: UIViewRepresentable {

    let package: ScanPackage

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene           = buildScene()
        scnView.allowsCameraControl = true   // pinch/rotate
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .black
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func buildScene() -> SCNScene {
        let scene = SCNScene()

        // Build vertex array
        let vertices = package.vertices.map {
            SCNVector3($0[0], $0[1], $0[2])
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)

        // Build face index data
        let indexData = Data(
            bytes: package.faces,
            count: package.faces.count * MemoryLayout<UInt32>.size
        )

        let element = SCNGeometryElement(
            data:           indexData,
            primitiveType:  .triangles,
            primitiveCount: package.faces.count / 3,
            bytesPerIndex:  MemoryLayout<UInt32>.size
        )

        let geometry  = SCNGeometry(
            sources:  [vertexSource],
            elements: [element]
        )

        // White wireframe-style material
        let material = SCNMaterial()
        material.diffuse.contents  = UIColor.white
        material.fillMode          = .fill
        material.isDoubleSided     = true
        geometry.materials         = [material]

        let meshNode = SCNNode(geometry: geometry)

        // Centre the mesh in view
        let (min, max) = meshNode.boundingBox
        let centre = SCNVector3(
            (min.x + max.x) / 2,
            (min.y + max.y) / 2,
            (min.z + max.z) / 2
        )
        meshNode.pivot = SCNMatrix4MakeTranslation(
            centre.x, centre.y, centre.z
        )

        scene.rootNode.addChildNode(meshNode)
        return scene
    }
}
