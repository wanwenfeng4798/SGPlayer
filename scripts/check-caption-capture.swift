#!/usr/bin/env swift
// Run on macOS against a composed capture exported from any demo platform.
// Usage: swift scripts/check-caption-capture.swift capture.png [expected text]
import Foundation
import Vision

let arguments = CommandLine.arguments
if arguments.count < 2 {
    fputs("Usage: check-caption-capture.swift capture.png [expected text]\n", stderr)
    exit(2)
}
let expected = arguments.count > 2 ? arguments[2] : "同步字幕"
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false
request.minimumTextHeight = 0.01
let url = URL(fileURLWithPath: arguments[1])
do {
    try VNImageRequestHandler(url: url).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let passed = lines.contains { $0.replacingOccurrences(of: " ", with: "").contains(expected.replacingOccurrences(of: " ", with: "")) }
    let report: [String: Any] = ["file": url.path, "expected": expected, "recognizedLines": lines, "passed": passed]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(passed ? 0 : 1)
} catch {
    fputs("Caption OCR failed: \(error)\n", stderr)
    exit(2)
}
