#!/usr/bin/env swift

import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/SprekrStart.aiff")
let sampleRate = 48_000.0
let duration = 0.27
let frameCount = Int(sampleRate * duration)

func smoothstep(_ value: Double) -> Double {
    let x = min(max(value, 0), 1)
    return x * x * (3 - 2 * x)
}

var lowerPhase = 0.0
var upperPhase = 0.0
var shimmerPhase = 0.0
var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)

func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

for frame in 0..<frameCount {
    let time = Double(frame) / sampleRate
    let attack = smoothstep(time / 0.009)
    let release = 1 - smoothstep((time - 0.105) / (duration - 0.105))
    let envelope = attack * release

    // A quick upward opening gesture that settles into the same G/D family as
    // SprekrCompletion. Integrating phase keeps the glide completely click-free.
    let lowerFrequency = 330 + (392 - 330) * smoothstep(time / 0.075)
    let upperFrequency = 494 + (587.33 - 494) * smoothstep((time - 0.018) / 0.085)
    lowerPhase += 2 * .pi * lowerFrequency / sampleRate
    upperPhase += 2 * .pi * upperFrequency / sampleRate
    shimmerPhase += 2 * .pi * 1_174.66 / sampleRate

    let upperEntrance = smoothstep((time - 0.026) / 0.035)
    let shimmerRelease = 1 - smoothstep((time - 0.035) / 0.105)
    let sample = envelope * (
        sin(lowerPhase) * 0.075
            + sin(upperPhase) * 0.052 * upperEntrance
            + sin(shimmerPhase) * 0.010 * shimmerRelease
    )
    let clamped = min(max(sample, -1), 1)
    appendBigEndian(Int16(clamped * Double(Int16.max)), to: &pcm)
}

var aiff = Data()
aiff.append(contentsOf: "FORM".utf8)
appendBigEndian(UInt32(46 + pcm.count), to: &aiff)
aiff.append(contentsOf: "AIFF".utf8)
aiff.append(contentsOf: "COMM".utf8)
appendBigEndian(UInt32(18), to: &aiff)
appendBigEndian(UInt16(1), to: &aiff)
appendBigEndian(UInt32(frameCount), to: &aiff)
appendBigEndian(UInt16(16), to: &aiff)
// 48,000 Hz as an IEEE 754 80-bit extended floating-point value.
aiff.append(contentsOf: [0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])
aiff.append(contentsOf: "SSND".utf8)
appendBigEndian(UInt32(8 + pcm.count), to: &aiff)
appendBigEndian(UInt32(0), to: &aiff)
appendBigEndian(UInt32(0), to: &aiff)
aiff.append(pcm)

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try aiff.write(to: outputURL, options: .atomic)
print(outputURL.path)
