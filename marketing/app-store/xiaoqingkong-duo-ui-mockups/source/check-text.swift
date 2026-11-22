import Foundation
import Vision

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = ["01-today": "了解身体", "02-mood": "感觉怎么样", "03-sleep": "轻轻放下来", "04-trends": "看见变化", "05-scenes": "换一种日常", "06-privacy": "隐私说明"]
var records: [[String: Any]] = []
for screen in ["outer", "inner"] {
    for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(screen), includingPropertiesForKeys: nil).filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "").filter { !$0.isWhitespace }
        let phrase = expected.first(where: { url.lastPathComponent.hasPrefix($0.key) })!.value
        let matched = text.contains(phrase)
        let noUnrequestedLabel = !["尚未经过", "DRAFT", "待核验", "小晴天"].contains(where: { text.contains($0) })
        records.append(["file": screen + "/" + url.lastPathComponent, "expected": phrase, "matched": matched, "noUnrequestedLabel": noUnrequestedLabel, "recognizedText": lines])
        print("\(matched && noUnrequestedLabel ? "PASS" : "FAIL") \(screen)/\(url.lastPathComponent) — \(phrase)")
    }
}
try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("text-verification.json"))
if records.count != 12 || records.contains(where: { !($0["matched"] as! Bool) || !($0["noUnrequestedLabel"] as! Bool) }) { exit(1) }
