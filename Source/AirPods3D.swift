import AppKit
import SceneKit
import SwiftUI

// 4.5.0 — a small 3D model of the connected earbuds that spins around its
// own axis in the island's left wing, like the connection animation on
// iPhone. Built from simple shapes (no image assets): glossy white buds
// with stems, or over-ear headphones when the name says «Max».
enum EarbudsModel {
    static func scene(headphones: Bool) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        let white = SCNMaterial()
        white.lightingModel = .physicallyBased
        white.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        white.roughness.contents = 0.22
        white.metalness.contents = 0.0
        let grey = SCNMaterial()
        grey.lightingModel = .physicallyBased
        grey.diffuse.contents = NSColor(white: 0.62, alpha: 1)
        grey.roughness.contents = 0.6
        let dark = SCNMaterial()
        dark.lightingModel = .physicallyBased
        dark.diffuse.contents = NSColor(white: 0.18, alpha: 1)
        dark.roughness.contents = 0.4

        if headphones {
            // Headband: an arc of short capsules; two cups with cushions.
            let segments = 14
            let radius: CGFloat = 0.95
            for i in 0..<segments {
                let a0 = CGFloat.pi * CGFloat(i) / CGFloat(segments)
                let a1 = CGFloat.pi * CGFloat(i + 1) / CGFloat(segments)
                let p0 = CGPoint(x: radius * cos(a0), y: radius * sin(a0))
                let p1 = CGPoint(x: radius * cos(a1), y: radius * sin(a1))
                let length = hypot(p1.x - p0.x, p1.y - p0.y)
                let piece = SCNCapsule(capRadius: 0.085, height: length + 0.17)
                piece.materials = [white]
                let node = SCNNode(geometry: piece)
                node.position = SCNVector3((p0.x + p1.x) / 2, (p0.y + p1.y) / 2 - 0.2, 0)
                node.eulerAngles.z = (a0 + a1) / 2
                root.addChildNode(node)
            }
            for side: CGFloat in [-1, 1] {
                let cup = SCNCapsule(capRadius: 0.36, height: 1.05)
                cup.materials = [white]
                let cupNode = SCNNode(geometry: cup)
                cupNode.position = SCNVector3(side * 0.95, -0.55, 0)
                cupNode.scale = SCNVector3(0.62, 1, 0.9)
                root.addChildNode(cupNode)
                let cushion = SCNCylinder(radius: 0.32, height: 0.12)
                cushion.materials = [grey]
                let cushionNode = SCNNode(geometry: cushion)
                cushionNode.eulerAngles.z = .pi / 2
                cushionNode.position = SCNVector3(side * 0.74, -0.55, 0)
                cushionNode.scale = SCNVector3(1, 1, 1.45)
                root.addChildNode(cushionNode)
            }
        } else {
            for side: CGFloat in [-1, 1] {
                let bud = SCNNode()
                // Head: a squashed sphere, with a dark grille and grey tip.
                let head = SCNSphere(radius: 0.36)
                head.segmentCount = 36
                head.materials = [white]
                let headNode = SCNNode(geometry: head)
                headNode.scale = SCNVector3(1, 0.92, 0.82)
                bud.addChildNode(headNode)
                let tip = SCNSphere(radius: 0.17)
                tip.materials = [grey]
                let tipNode = SCNNode(geometry: tip)
                tipNode.position = SCNVector3(side * -0.2, 0.06, 0.24)
                bud.addChildNode(tipNode)
                let grille = SCNCapsule(capRadius: 0.035, height: 0.16)
                grille.materials = [dark]
                let grilleNode = SCNNode(geometry: grille)
                grilleNode.eulerAngles.z = .pi / 2
                grilleNode.position = SCNVector3(side * 0.08, 0.2, -0.24)
                bud.addChildNode(grilleNode)
                // Stem.
                let stem = SCNCapsule(capRadius: 0.1, height: 0.95)
                stem.materials = [white]
                let stemNode = SCNNode(geometry: stem)
                stemNode.position = SCNVector3(side * 0.1, -0.52, -0.06)
                stemNode.eulerAngles.z = side * 0.12
                bud.addChildNode(stemNode)
                bud.position = SCNVector3(side * 0.48, 0.22, 0)
                bud.eulerAngles.y = side * -0.35
                root.addChildNode(bud)
            }
        }

        // One full turn every 3.6 s, forever, plus a gentle tilt.
        root.eulerAngles.x = 0.12
        root.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 3.6)))

        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.wantsHDR = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, headphones ? 5.4 : 4.8)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)
        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 420
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)
        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 500
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-3, 2, -3)
        scene.rootNode.addChildNode(rimNode)
        return scene
    }
}

struct SpinningEarbudsView: NSViewRepresentable {
    var headphones: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.scene = EarbudsModel.scene(headphones: headphones)
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = EnergySaver.isActive ? 30 : 60
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    static func dismantleNSView(_ view: SCNView, coordinator: ()) {
        view.isPlaying = false
        view.scene = nil
    }
}
