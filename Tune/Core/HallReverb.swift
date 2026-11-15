import Foundation

/// Freeverb из Tune Native. Правый канал использует чуть более длинные задержки.
struct HallReverb {
    private static let combLengths = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassLengths = [556, 441, 341, 225]

    private struct Delay {
        var samples: [Float]
        var index = 0
        var damped: Float = 0

        mutating func comb(_ input: Float) -> Float {
            let delayed = samples[index]
            damped = delayed * 0.75 + damped * 0.25
            if abs(damped) < 1e-20 { damped = 0 }
            samples[index] = input + damped * 0.86
            advance()
            return delayed
        }

        mutating func allpass(_ input: Float) -> Float {
            let delayed = samples[index]
            samples[index] = input + delayed * 0.5
            advance()
            return delayed - input
        }

        private mutating func advance() {
            index += 1
            if index == samples.count { index = 0 }
        }

        mutating func reset() {
            for index in samples.indices { samples[index] = 0 }
            index = 0
            damped = 0
        }
    }

    private var combs: [Delay]
    private var allpasses: [Delay]

    init(rate: Float, channel: Int) {
        let spread = channel.isMultiple(of: 2) ? 0 : 23
        func line(_ length: Int) -> Delay {
            let count = max(1, Int((Float(length + spread) * rate / 44_100).rounded()))
            return Delay(samples: Array(repeating: 0, count: count))
        }
        combs = Self.combLengths.map(line)
        allpasses = Self.allpassLengths.map(line)
    }

    mutating func render(_ input: Float) -> Float {
        var output: Float = 0
        for index in combs.indices { output += combs[index].comb(input) }
        for index in allpasses.indices { output = allpasses[index].allpass(output) }
        return output
    }

    mutating func reset() {
        for index in combs.indices { combs[index].reset() }
        for index in allpasses.indices { allpasses[index].reset() }
    }
}
