import Foundation

/// A note of the written-out score, timed in reference seconds (tempo markings already applied).
public struct ReferenceNote {
    public var onset: Double
    public var duration: Double
    public var pitch: UInt8
    public var velocity: UInt8

    public init(onset: Double, duration: Double, pitch: UInt8, velocity: UInt8 = 64) {
        self.onset = onset
        self.duration = duration
        self.pitch = pitch
        self.velocity = velocity
    }
}
