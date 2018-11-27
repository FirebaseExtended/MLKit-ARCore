//
//  Copyright (c) 2018 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import SceneKit
import ARKit
import Firebase
import ARCore

class ViewController: UIViewController {

  private var gSession: GARSession!
  lazy var anchorReference = Database.database().reference(withPath: "anchors")

  // SCENE
  @IBOutlet var sceneView: ARSCNView!
  let bubbleDepth : Float = 0.01 // the 'depth' of 3D text
  var latestPrediction : String = "…" // a variable containing the latest ML Kit prediction
  private var anchors = [UUID : String]()
  private var canchors = [String : String]()
  private var anchorSet: Set<String> = []

  // ML Kit
  private lazy var vision = Vision.vision()
  let dispatchQueueML = DispatchQueue(label: "dispatchqueueml", autoreleaseFrequency: .workItem) // A Serial Queue
  @IBOutlet weak var debugTextView: UITextView!

  override func viewDidLoad() {
    super.viewDidLoad()

    // Set the view's delegate
    sceneView.delegate = self

    sceneView.session.delegate = self
    try? gSession = GARSession(apiKey: "AIzaSyBioT6F4ZjqnZIemPOqONRLrTQQuQZrEtg", bundleIdentifier: nil)
    gSession.delegate = self
    gSession.delegateQueue = DispatchQueue.main

    // Show statistics such as fps and timing information
    sceneView.showsStatistics = true

    // Create a new scene
    let scene = SCNScene()

    // Set the scene to the view
    sceneView.scene = scene

    // Enable Default Lighting - makes the 3D text a bit poppier.
    sceneView.autoenablesDefaultLighting = true

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self.resolveAnchors()
    }

    // Tap Gesture Recognizer
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(gestureRecognize:)))
    view.addGestureRecognizer(tapGesture)

    // Begin Loop to Update ML Kit
    loopMLKitUpdate()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    // Create a session configuration
    let configuration = ARWorldTrackingConfiguration()
    // Enable plane detection
    configuration.planeDetection = .horizontal

    // Run the view's session
    sceneView.session.run(configuration)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)

    // Pause the view's session
    sceneView.session.pause()
    anchorReference.removeAllObservers()
  }

  // MARK: - Status Bar: Hide
  override var prefersStatusBarHidden : Bool {
    return true
  }

  // MARK: - Interaction

  @objc func handleTap(gestureRecognize: UITapGestureRecognizer) {
    // HIT TEST : REAL WORLD
    // Get Screen Centre
    let screenCentre : CGPoint = CGPoint(x: self.sceneView.bounds.midX, y: self.sceneView.bounds.midY)

    let arHitTestResults : [ARHitTestResult] = sceneView.hitTest(screenCentre, types: [.featurePoint]) // Alternatively, we could use '.existingPlaneUsingExtent' for more grounded hit-test-points.

    if let closestResult = arHitTestResults.first {
      // Get Coordinates of HitTest
      let transform : matrix_float4x4 = closestResult.worldTransform
      let arAnchor = ARAnchor(transform: transform)
      sceneView.session.add(anchor: arAnchor)
      // To share an anchor, we call host anchor here on the ARCore session.
      // session:didHostAnchor: session:didFailToHostAnchor: will get called appropriately.
      if let cloudAnchor = try? gSession.hostCloudAnchor(arAnchor) {
        anchors.updateValue(latestPrediction, forKey: cloudAnchor.identifier)
        addLabel(latestPrediction, withTransform: transform, identifier: cloudAnchor.identifier)
      }
    }
  }

  func addLabel(_ label: String, withTransform transform: matrix_float4x4, identifier: UUID?) {
    let worldCoord : SCNVector3 = SCNVector3Make(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

    // Create 3D Text
    let node : SCNNode = createNewBubbleParentNode(label, identifier: identifier)
    sceneView.scene.rootNode.addChildNode(node)
    node.position = worldCoord
  }

  func createNewBubbleParentNode(_ text: String, identifier: UUID?) -> SCNNode {
    // Warning: Creating 3D Text is susceptible to crashing. To reduce chances of crashing; reduce number of polygons, letters, smoothness, etc.

    // TEXT BILLBOARD CONSTRAINT
    let billboardConstraint = SCNBillboardConstraint()
    billboardConstraint.freeAxes = SCNBillboardAxis.Y

    // BUBBLE-TEXT
    let bubble = SCNText(string: text, extrusionDepth: CGFloat(bubbleDepth))
    if let identifier = identifier, let visionImage = createVisionImage() {
      let options = VisionCloudDetectorOptions()
      options.maxResults = 1
      vision.cloudLabelDetector(options: options).detect(in: visionImage) { labels, error in
        guard error == nil, let labels = labels, !labels.isEmpty, let label = labels[0].label else { return }
        self.anchors.updateValue(label, forKey: identifier)
        bubble.string = label
      }
    }

    var font = UIFont(name: "Futura", size: 0.15)
    font = font?.withTraits(traits: .traitBold)
    bubble.font = font
    bubble.alignmentMode = kCAAlignmentCenter
    bubble.firstMaterial?.diffuse.contents = UIColor.orange
    bubble.firstMaterial?.specular.contents = UIColor.white
    bubble.firstMaterial?.isDoubleSided = true
    // bubble.flatness // setting this too low can cause crashes.
    bubble.chamferRadius = CGFloat(bubbleDepth)

    // BUBBLE NODE
    let (minBound, maxBound) = bubble.boundingBox
    let bubbleNode = SCNNode(geometry: bubble)
    // Centre Node - to Centre-Bottom point
    bubbleNode.pivot = SCNMatrix4MakeTranslation( (maxBound.x - minBound.x)/2, minBound.y, bubbleDepth/2)
    // Reduce default text size
    bubbleNode.scale = SCNVector3Make(0.2, 0.2, 0.2)

    // CENTRE POINT NODE
    let sphere = SCNSphere(radius: 0.005)
    sphere.firstMaterial?.diffuse.contents = UIColor.cyan
    let sphereNode = SCNNode(geometry: sphere)

    // BUBBLE PARENT NODE
    let bubbleNodeParent = SCNNode()
    bubbleNodeParent.addChildNode(bubbleNode)
    bubbleNodeParent.addChildNode(sphereNode)
    bubbleNodeParent.constraints = [billboardConstraint]

    return bubbleNodeParent
  }

  // MARK: - ML Kit Vision Handling

  func loopMLKitUpdate() {
    // Continuously run ML Kit whenever it's ready. (Preventing 'hiccups' in Frame Rate)
    dispatchQueueML.async {
      // 1. Run Update.
      self.updateMLKit()

      // 2. Loop this function.
      self.loopMLKitUpdate()
    }
  }

  private func createVisionImage() -> VisionImage? {
    guard let pixbuff : CVPixelBuffer? = sceneView.session.currentFrame?.capturedImage else {
      return nil
    }
    let ciImage = CIImage(cvPixelBuffer: pixbuff!)

    let context = CIContext.init(options: nil)

    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      return nil
    }
    let rotatedImage =
      UIImage.init(cgImage: cgImage, scale: 1.0, orientation: .right)
    guard let rotatedCGImage = rotatedImage.cgImage else {
      return nil
    }
    let mirroredImage = UIImage.init(
      cgImage: rotatedCGImage, scale: 1.0, orientation: .leftMirrored)

    return VisionImage.init(image: mirroredImage)
  }

  func updateMLKit() {
    guard let visionImage = createVisionImage() else { return }
    let group = DispatchGroup()
    let options = VisionLabelDetectorOptions.init(confidenceThreshold: 0.7)
    group.enter()
    vision.labelDetector().detect(in: visionImage) { features, error in
      defer { group.leave() }
      guard error == nil, let features = features, !features.isEmpty else {
        let errorString = error?.localizedDescription ?? "detectionNoResultsMessage"
        print("On-Device label detection failed with error: \(errorString)")
        return
      }

      // Get Classifications
      let classifications = features
        .map { feature -> String in
          "\(feature.label) \(String(format:"- %.2f", feature.confidence))" }
        .joined(separator: "\n")

      DispatchQueue.main.async {
        // Display Debug Text on screen
        var debugText:String = ""
        debugText += classifications
        self.debugTextView.text = debugText

        // Store the latest prediction
        var objectName:String = "…"
        objectName = classifications.components(separatedBy: "-")[0]
        objectName = objectName.components(separatedBy: ",")[0]
        self.latestPrediction = objectName

      }
    }
    group.wait()
  }

  // MARK: - Anchor Hosting / Resolving
  func resolveAnchors() {
    weak var weakSelf: ViewController? = self
    anchorReference.observe(.childAdded) { snapshot in

      DispatchQueue.main.async(execute: {
        guard let strongSelf = weakSelf else { return }
        if !strongSelf.anchorSet.contains(snapshot.key) {
          self.canchors.updateValue(snapshot.value as! String, forKey: snapshot.key)
          strongSelf.resolveAnchor(snapshot.value as! String, withIdentifier: snapshot.key)
        }
      })
    }
  }

  func resolveAnchor(_ label: String, withIdentifier identifier: String) {
    // Now that we have the anchor ID from Firebase, we resolve the anchor.
    // Success and failure of this call is handled by the delegate methods
    // session:didResolveAnchor and session:didFailToResolveAnchor appropriately.
    if let _ = try? gSession.resolveCloudAnchor(withIdentifier: identifier) {
      anchorSet.insert(identifier)
    }
  }
}

extension ViewController: GARSessionDelegate {

  func session(_ session: GARSession, didHostAnchor anchor: GARAnchor) {
    anchorSet.insert(anchor.cloudIdentifier!)
    anchorReference.child(anchor.cloudIdentifier!).setValue(anchors[anchor.identifier])
  }

  func session(_ session: GARSession, didFailToHostAnchor anchor: GARAnchor) {
    print("Did fail to host \(anchor.identifier)")
  }

  func session(_ session: GARSession, didResolve anchor: GARAnchor) {
    let arAnchor = ARAnchor(transform: anchor.transform)
    sceneView.session.add(anchor: arAnchor)
    addLabel(canchors[anchor.cloudIdentifier!] ?? "", withTransform: arAnchor.transform, identifier: nil)
  }

  func session(_ session: GARSession, didFailToResolve anchor: GARAnchor) {
    print("Did fail to resolve \(anchor.cloudIdentifier ?? anchor.identifier.uuidString)")
  }
}

extension ViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // Forward ARKit's update to ARCore session
    try! gSession.update(frame)
  }
}

extension ViewController: ARSCNViewDelegate {

  func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    if (anchor is ARPlaneAnchor) {
      let planeAnchor = anchor as? ARPlaneAnchor

      let width = CGFloat(planeAnchor?.extent.x ?? 0.0)
      let height = CGFloat(planeAnchor?.extent.z ?? 0.0)
      let plane = SCNPlane(width: width, height: height)

      plane.materials.first?.diffuse.contents = UIColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 0.3)

      let planeNode = SCNNode(geometry: plane)

      let x = CGFloat(planeAnchor?.center.x ?? 0.0)
      let y = CGFloat(planeAnchor?.center.y ?? 0.0)
      let z = CGFloat(planeAnchor?.center.z ?? 0.0)
      planeNode.position = SCNVector3Make(Float(x), Float(y), Float(z))
      planeNode.eulerAngles = SCNVector3Make(-.pi / 2, 0, 0)

      node.addChildNode(planeNode)
    }
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    if (anchor is ARPlaneAnchor) {
      let planeAnchor = anchor as? ARPlaneAnchor

      let planeNode: SCNNode? = node.childNodes.first
      let plane = planeNode?.geometry as? SCNPlane

      let width = CGFloat(planeAnchor?.extent.x ?? 0.0)
      let height = CGFloat(planeAnchor?.extent.z ?? 0.0)
      plane?.width = width
      plane?.height = height

      let x = CGFloat(planeAnchor?.center.x ?? 0.0)
      let y = CGFloat(planeAnchor?.center.y ?? 0.0)
      let z = CGFloat(planeAnchor?.center.z ?? 0.0)
      planeNode?.position = SCNVector3Make(Float(x), Float(y), Float(z))
    }
  }
}


extension UIFont {
  // Based on: https://stackoverflow.com/questions/4713236/how-do-i-set-bold-and-italic-on-uilabel-of-iphone-ipad
  func withTraits(traits:UIFontDescriptorSymbolicTraits...) -> UIFont {
    let descriptor = self.fontDescriptor.withSymbolicTraits(UIFontDescriptorSymbolicTraits(traits))
    return UIFont(descriptor: descriptor!, size: 0)
  }
}
