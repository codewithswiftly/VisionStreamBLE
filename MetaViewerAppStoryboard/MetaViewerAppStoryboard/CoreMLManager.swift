import Vision
import CoreML

final class CoreMLManager {

    // MARK: - Models

    private lazy var createMLModel: VNCoreMLModel = {
        let model = try! SnapLearnImageClassifier(configuration: .init()).model
        return try! VNCoreMLModel(for: model)
    }()

    private lazy var mobileNetModel: VNCoreMLModel = {
        let model = try! MobileNetV2(configuration: .init()).model
        return try! VNCoreMLModel(for: model)
    }()

    // MARK: - Public API

    func classify(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        completion: @escaping (String) -> Void
    ) {
        self.runMobileNet(
            cgImage: cgImage,
            orientation: orientation,
            completion: completion
        )

//        runCreateML(
//            cgImage: cgImage,
//            orientation: orientation
//        ) { label, confidence in
//
//            // 👇 Decision logic
//            if confidence > 0.9 {
//                completion(label)
//            } else {
//            }
//        }
    }

    // MARK: - Create ML First Pass

    private func runCreateML(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        completion: @escaping (String, Float) -> Void
    ) {

        let request = VNCoreMLRequest(model: createMLModel) { request, _ in
            let results = request.results as? [VNClassificationObservation]
            let best = results?.first

            completion(
                best?.identifier.capitalized ?? "Unknown",
                best?.confidence ?? 0
            )
        }

        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation
        )

        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    // MARK: - MobileNet Fallback

    private func runMobileNet(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        completion: @escaping (String) -> Void
    ) {

        let request = VNCoreMLRequest(model: createMLModel) { request, _ in
            let results = (request.results as? [VNClassificationObservation]) ?? []
            let best = VisionLabelFilter.bestLabel(from: results)


            completion(
                best.capitalized
            )
        }

        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation
        )

        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
}

struct VisionLabelFilter {
    
    static let genericKeywords = [
        "device",
        "equipment",
        "hardware",
        "electronics",
        "material",
        "object",
        "machine",
        "material",
        "texture",
        "pattern",
        "paper",
        "surface",
        "background",
        "fabric",
        "structure",
        "textile"
    ]
    
    static func bestLabel(from observations: [VNClassificationObservation]) -> String {
        let sorted = observations.sorted { print($0.identifier + "->" + String($0.confidence))
            return $0.confidence > $1.confidence }

            // 1️⃣ Prefer specific labels
            if let specific = sorted.first(where: { obs in
                
                let label = obs.identifier.lowercased()
                return obs.confidence > 0.4 &&
                !genericKeywords.contains(where: { label.contains($0) })
            }) {
                return specific.identifier.capitalized
            }

            // 2️⃣ Fallback to highest confidence
            if let top = sorted.first {
                return top.identifier.capitalized
            }

            return "Unknown object"
    }
}
