// Follows a recording of a performance against a score's reference and writes what it found.
//
//   piano-tracker --performance perf.wav --out dir --hop 1024 --fft 2048 [--tuning 0]
//                 (--reference-audio ref.wav --last-onset seconds | --reference-notes notes.csv --sound-bank piano.sf2)
//                 [--synth 1]   render the reference with SynthReference instead of a SoundFont
//                 [--silence-gate 0|1] [--recovery 0|1]
//                 [--room-noise room.wav]  a recording of the room with nobody playing
//                 [--floor-margin 2] [--start-frames 5] [--min-peakiness 0.62]
//                 [--freeze-in-rests 0|1] [--rest-peakiness 0.5] [--rest-hold 0.3] [--rest-level 0.01]
//                 [--reanchor 0|1] [--reanchor-after 2] [--resume-frames 3]
//                 [--calibrate-seconds 2] [--calibration-margin 0.05] [--max-peakiness 0.7]
//                 [--back-step 0] [--local-reanchor 0|1] [--local-reach 4] [--local-improvement 0.9]
//                 [--local-every 1] [--local-pace 0.8:1.25|any]
//                     the settings the README's figures use: --back-step 1 --local-reanchor 1
//                     --local-reach 1.5 --local-improvement 0.7 --local-every 2
//                 [--timeline timeline.csv]   quarters,seconds of the plan's timeline
//                 [--bars bars.csv]   quarters of each played bar's start, to bound recovery in bars
//                 [--movement-starts s1,s2,...]   reference seconds where each later movement starts
//                 [--start-quarters Q]   the pianist's own starting point, in quarter notes
//                 [--jump-at T --jump-quarters Q]   as if the pianist said "restarting from bar ..." at time T
//                 [--bounded-recovery 0|1] [--recovery-bars-back 8] [--recovery-bars-ahead 8]
//                 [--progress-rate 1.5] [--context-seconds 10] [--confirm-seconds 1.5]
//                 [--confirm-improvement 0.9] [--trust-seconds 2] [--trust-confidence 0.3]
//                 [--finish-hold 0.25] [--distant 0|1] [--distant-after 5] [--distant-margin 1.3]
//                 [--catch-up-bars 32] [--catch-up-margin 1.3] [--catch-up-confirm 5]
//                 [--members 2,1,0.5,0.25 [--opening-bars 10] [--opening-seconds 60] [--preference 0.05]]
//                     a follower per tempo, each rendered from --reference-notes, the best fit kept
//                     after the opening bars (TempoChoice)
//
// Audio is WAV: 16-, 24- or 32-bit integer or 32-bit float, any number of channels (averaged). The
// performance and the reference must share a sample rate. notes.csv is onset,duration,pitch per
// line, in reference seconds (Plan.referenceNotes).
//
// Writes to dir: reference_features.f32 and input_features.f32 (12 per frame), positions.f64
// (time, reference seconds per frame), diagnostics.f64 (time, reference seconds, confidence,
// silent, relocated), gate.f64 (time, level, peakiness), recovery.f64 (relocation 0 none / 1 local
// / 2 structural, state 0 tracking / 1 uncertain / 2 confirming, accepted reference seconds, anchor
// reference seconds, matched frame's distance), and reference_audio.f32 when rendering.

import Foundation
import SoloPianoTracker

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let key = arguments.popFirst() {
    guard key.hasPrefix("--"), let value = arguments.popFirst() else { fail("expected --option value, got \(key)") }
    options[String(key.dropFirst(2))] = value
}
func option(_ name: String) -> String {
    guard let value = options[name] else { fail("missing --\(name)") }
    return value
}
func flag(_ name: String, _ fallback: Bool) -> Bool {
    guard let value = options[name] else { return fallback }
    return value != "0" && value.lowercased() != "false"
}
func number(_ name: String, _ fallback: Double) -> Double {
    options[name].flatMap(Double.init) ?? fallback
}

/// Mono float samples from a WAV file, averaging channels like librosa.load.
func loadAudio(_ path: String) throws -> (samples: [Float], sampleRate: Double) {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func u16(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { u16(at) | u16(at + 2) << 16 }
    func tag(_ at: Int) -> String { String(decoding: bytes[at..<(at + 4)], as: UTF8.self) }
    guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { fail("\(path) is not a WAV file") }
    var format: UInt32 = 0, channels = 0, rate = 0, bits = 0
    var body: Range<Int>?
    var at = 12
    while at + 8 <= bytes.count {
        let size = Int(u32(at + 4)), start = at + 8
        if tag(at) == "fmt " {
            format = u16(start)
            channels = Int(u16(start + 2))
            rate = Int(u32(start + 4))
            bits = Int(u16(start + 14))
            if format == 0xFFFE, size >= 26 { format = u16(start + 24) }  // extensible: the subformat's tag
        } else if tag(at) == "data" {
            body = start..<min(start + size, bytes.count)
        }
        at = start + size + (size & 1)
    }
    let width = bits / 8
    guard let body, channels > 0, (format == 1 && (2...4).contains(width)) || (format == 3 && width == 4) else {
        fail("\(path): not 16-, 24- or 32-bit integer or 32-bit float PCM")
    }
    let frames = body.count / (width * channels)
    var mono = [Float](repeating: 0, count: frames)
    for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<channels {
            let p = body.lowerBound + (i * channels + c) * width
            switch (format, width) {
            case (3, _): sum += Float(bitPattern: u32(p))
            case (_, 2): sum += Float(Int16(bitPattern: UInt16(u16(p)))) / 32768
            case (_, 3): sum += Float(Int32(bitPattern: (u16(p) | UInt32(bytes[p + 2]) << 16) << 8) >> 8) / 8388608
            default: sum += Float(Int32(bitPattern: u32(p))) / 2147483648
            }
        }
        mono[i] = channels > 1 ? sum / Float(channels) : sum
    }
    return (mono, Double(rate))
}

/// The rows of numbers in a CSV file. A header is any line that is not all numbers: the notes files
/// have none, and skipping the first line regardless dropped the first note of every reference.
func readRows(_ path: String) throws -> [[Double]] {
    try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { line -> [Double]? in
            let fields = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return fields.isEmpty || fields.contains(nil) ? nil : fields.compactMap { $0 }
        }
}

func write<T>(_ values: [T], to url: URL) throws {
    try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
}

do {
    let out = URL(fileURLWithPath: option("out"), isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let performance = try loadAudio(option("performance"))
    let extractor = ChromaExtractor(sampleRate: performance.sampleRate, hopLength: Int(option("hop"))!,
                                    fftLength: Int(option("fft"))!, tuning: number("tuning", 0),
                                    lowestHz: number("lowest-hz", 0))

    let referenceAudio: [Float]
    let lastOnset: Double
    var referenceNotes: [ReferenceNote] = []
    let memberRates = (options["members"] ?? "").split(separator: ",").compactMap { Double($0) }
    if let path = options["reference-audio"] {
        let reference = try loadAudio(path)
        guard reference.sampleRate == performance.sampleRate else { fail("sample rates differ") }
        referenceAudio = reference.samples
        lastOnset = Double(option("last-onset"))!
    } else {
        let notes = try readRows(option("reference-notes")).map {
            ReferenceNote(onset: $0[0], duration: $0[1], pitch: UInt8($0[2]))
        }
        lastOnset = notes.map(\.onset).max() ?? 0
        referenceNotes = notes
        let started = Date()
        referenceAudio = !memberRates.isEmpty ? []  // each member renders its own
            : flag("synth", false)
            ? SynthReference(sampleRate: performance.sampleRate).render(notes)
            : try SoundFontRenderer(soundBank: URL(fileURLWithPath: option("sound-bank")),
                                    sampleRate: performance.sampleRate).render(notes)
        print(String(format: "rendered %.1f s of reference in %.2f s",
                     Double(referenceAudio.count) / performance.sampleRate, Date().timeIntervalSince(started)))
        if !flag("synth", false) { try write(referenceAudio, to: out.appendingPathComponent("reference_audio.f32")) }
    }

    var followerOptions = FollowerOptions()
    followerOptions.silenceGate = flag("silence-gate", true)
    followerOptions.recovery = flag("recovery", true)
    followerOptions.gateOnlyBeforeFirstNote = flag("gate-only-before-first-note", true)
    followerOptions.gateBetweenMovements = flag("gate-between-movements", true)
    followerOptions.recoverySeconds = number("recovery-seconds", followerOptions.recoverySeconds)
    followerOptions.searchMargin = Float(number("search-margin", Double(followerOptions.searchMargin)))
    followerOptions.lostForSeconds = number("lost-for", followerOptions.lostForSeconds)
    followerOptions.lostBelow = Float(number("lost-below", Double(followerOptions.lostBelow)))
    followerOptions.floorMargin = Float(number("floor-margin", Double(followerOptions.floorMargin)))
    followerOptions.startFrames = Int(number("start-frames", Double(followerOptions.startFrames)))
    followerOptions.minPeakiness = Float(number("min-peakiness", Double(followerOptions.minPeakiness)))
    followerOptions.subtractNoise = Float(number("subtract", Double(followerOptions.subtractNoise)))
    followerOptions.absoluteSilence = Float(number("absolute-silence", Double(followerOptions.absoluteSilence)))
    followerOptions.freezeInRests = flag("freeze-in-rests", followerOptions.freezeInRests)
    followerOptions.restLevel = Float(number("rest-level", Double(followerOptions.restLevel)))
    followerOptions.restPeakiness = Float(number("rest-peakiness", Double(followerOptions.restPeakiness)))
    followerOptions.restHoldSeconds = number("rest-hold", followerOptions.restHoldSeconds)
    followerOptions.reanchorAfterRest = flag("reanchor", followerOptions.reanchorAfterRest)
    followerOptions.reanchorAfterSeconds = number("reanchor-after", followerOptions.reanchorAfterSeconds)
    followerOptions.resumeFrames = Int(number("resume-frames", Double(followerOptions.resumeFrames)))
    followerOptions.calibrateSeconds = number("calibrate-seconds", followerOptions.calibrateSeconds)
    followerOptions.calibrationMargin = Float(number("calibration-margin", Double(followerOptions.calibrationMargin)))
    followerOptions.maxPeakiness = Float(number("max-peakiness", Double(followerOptions.maxPeakiness)))
    followerOptions.localReanchor = flag("local-reanchor", followerOptions.localReanchor)
    followerOptions.localSeconds = number("local-seconds", followerOptions.localSeconds)
    followerOptions.localReachSeconds = number("local-reach", followerOptions.localReachSeconds)
    followerOptions.localEverySeconds = number("local-every", followerOptions.localEverySeconds)
    followerOptions.localImprovement = Float(number("local-improvement", Double(followerOptions.localImprovement)))
    followerOptions.boundedRecovery = flag("bounded-recovery", followerOptions.boundedRecovery)
    followerOptions.recoveryBarsBack = number("recovery-bars-back", followerOptions.recoveryBarsBack)
    followerOptions.recoveryBarsAhead = number("recovery-bars-ahead", followerOptions.recoveryBarsAhead)
    followerOptions.recoveryProgressRate = number("progress-rate", followerOptions.recoveryProgressRate)
    followerOptions.recoveryContextSeconds = number("context-seconds", followerOptions.recoveryContextSeconds)
    followerOptions.candidateFit = Float(number("candidate-fit", Double(followerOptions.candidateFit)))
    followerOptions.confirmSeconds = number("confirm-seconds", followerOptions.confirmSeconds)
    followerOptions.confirmImprovement = Float(number("confirm-improvement", Double(followerOptions.confirmImprovement)))
    followerOptions.confirmConfidence = Float(number("confirm-confidence", Double(followerOptions.confirmConfidence)))
    followerOptions.confirmMinRate = number("confirm-min-rate", followerOptions.confirmMinRate)
    followerOptions.confirmMaxRate = number("confirm-max-rate", followerOptions.confirmMaxRate)
    followerOptions.confirmBySearch = flag("confirm-by-search", followerOptions.confirmBySearch)
    followerOptions.agreeMargin = Float(number("agree-margin", Double(followerOptions.agreeMargin)))
    followerOptions.catchUpBarsAhead = number("catch-up-bars", followerOptions.catchUpBarsAhead)
    followerOptions.catchUpMargin = Float(number("catch-up-margin", Double(followerOptions.catchUpMargin)))
    followerOptions.catchUpConfirmSeconds = number("catch-up-confirm", followerOptions.catchUpConfirmSeconds)
    followerOptions.catchUpMemorySeconds = number("catch-up-memory", followerOptions.catchUpMemorySeconds)
    followerOptions.holdWhileUncertain = flag("hold-while-uncertain", followerOptions.holdWhileUncertain)
    if let range = options["local-pace"] {  // "0.8:1.25", or "any"
        let ends = range.split(whereSeparator: { $0 == ":" || $0 == "," }).compactMap { Double($0) }
        followerOptions.localPaceRange = ends.count == 2 ? ends[0]...ends[1] : nil
    }
    followerOptions.localPaceSeconds = number("local-pace-seconds", followerOptions.localPaceSeconds)
    followerOptions.trustSeconds = number("trust-seconds", followerOptions.trustSeconds)
    followerOptions.trustConfidence = Float(number("trust-confidence", Double(followerOptions.trustConfidence)))
    followerOptions.finishHoldSeconds = number("finish-hold", followerOptions.finishHoldSeconds)
    followerOptions.distantRecovery = flag("distant", followerOptions.distantRecovery)
    followerOptions.distantAfterSeconds = number("distant-after", followerOptions.distantAfterSeconds)
    followerOptions.distantMargin = Float(number("distant-margin", Double(followerOptions.distantMargin)))
    followerOptions.distantConfirmSeconds = number("distant-confirm", followerOptions.distantConfirmSeconds)
    followerOptions.minJumpSeconds = number("min-jump", followerOptions.minJumpSeconds)
    if let rates = options["search-rates"] {
        followerOptions.searchRates = rates.split(separator: ",").compactMap { Double($0) }
    }

    // A recording of the room with nobody playing
    var room: RoomNoise?
    if let path = options["room-noise"] {
        let recording = try loadAudio(path)
        guard recording.sampleRate == performance.sampleRate else { fail("room noise sample rate differs") }
        room = RoomNoise(recording: recording.samples, extractor: extractor)
        print(String(format: "room noise: %.5f RMS (%.1f dB) over %.1f s",
                     Double(room!.level), 20 * log10(Double(max(room!.level, 1e-9))),
                     Double(recording.samples.count) / recording.sampleRate))
    }

    var started = Date()
    // Where the movements begin, in reference seconds, so the start gate can be put back on at each
    let movementStarts = (options["movement-starts"] ?? "")
        .split(separator: ",").compactMap { Double($0) }
    // Where each played bar starts, in reference seconds, which is what bounds recovery in bars
    var barStarts: [Double] = []
    if let path = options["bars"], let timelinePath = options["timeline"] {
        let cells = try readRows(timelinePath)
        let line = ReferenceTimeline(quarters: cells.map { $0[0] }, seconds: cells.map { $0[1] })
        barStarts = try readRows(path).map { line.seconds(atQuarters: $0[0]) }
    }
    // --stretch F follows the reference's features stretched F times longer, as if rendered at 1/F
    // of its tempo, instead of rendering again (the timeline passed must be stretched to match)
    let stretch = number("stretch", 1)
    let follower: ScoreFollower
    var choice: TempoChoice?
    if !memberRates.isEmpty {
        // Already rendered references, one per tempo, if given
        var memberAudio: [Double: String] = [:]
        for entry in (options["member-audio"] ?? "").split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let rate = Double(parts[0]) { memberAudio[rate] = String(parts[1]) }
        }
        guard !referenceNotes.isEmpty || !memberAudio.isEmpty else { fail("--members needs --reference-notes") }
        let members = try memberRates.map { rate in
            let reference: (features: [[Float]], levels: [Float])
            if let path = memberAudio[rate] {
                let audio = try loadAudio(path).samples
                reference = (extractor.chromagram(of: audio),
                             ScoreFollower.frameLevels(of: audio, fftLength: extractor.fftLength,
                                                       hopLength: extractor.hopLength))
            } else {
                let notes = referenceNotes.map {
                    ReferenceNote(onset: $0.onset / rate, duration: $0.duration / rate, pitch: $0.pitch, velocity: $0.velocity)
                }
                if let bank = options["sound-bank"] {
                    reference = try SoundFontRenderer(soundBank: URL(fileURLWithPath: bank),
                                                      sampleRate: performance.sampleRate)
                        .analyse(notes, extractor: extractor)
                } else {
                    reference = SynthReference(sampleRate: performance.sampleRate).analyse(notes, extractor: extractor)
                }
            }
            return TempoChoice.Member(rate: rate, follower: ScoreFollower(
                referenceFeatures: reference.features, referenceLevels: reference.levels, lastOnset: lastOnset / rate,
                extractor: extractor, options: followerOptions, room: room,
                movementStarts: movementStarts.map { $0 / rate }, barStarts: barStarts.map { $0 / rate },
                backStep: Int(number("back-step", 0))))
        }
        let chooser = TempoChoice(members: members, barStarts: barStarts)
        chooser.openingBars = number("opening-bars", chooser.openingBars)
        chooser.openingSeconds = number("opening-seconds", chooser.openingSeconds)
        chooser.windowSeconds = number("choice-window", chooser.windowSeconds)
        chooser.preference = number("preference", chooser.preference)
        chooser.showLeader = flag("show-leader", chooser.showLeader)
        choice = chooser
        follower = members[chooser.preferred].follower
    } else if stretch != 1 {
        let (features, levels) = ScoreFollower.stretched(
            extractor.chromagram(of: referenceAudio),
            levels: ScoreFollower.frameLevels(of: referenceAudio, fftLength: extractor.fftLength,
                                              hopLength: extractor.hopLength),
            by: stretch)
        follower = ScoreFollower(referenceFeatures: features, referenceLevels: levels, lastOnset: lastOnset * stretch,
                                 extractor: extractor, options: followerOptions, room: room,
                                 movementStarts: movementStarts, barStarts: barStarts,
                                 backStep: Int(number("back-step", 0)))
    } else {
        follower = ScoreFollower(referenceAudio: referenceAudio, lastOnset: lastOnset, extractor: extractor,
                                 options: followerOptions, room: room, movementStarts: movementStarts,
                                 barStarts: barStarts, backStep: Int(number("back-step", 0)))
    }
    print(String(format: "reference: %d frames in %.2f s", follower.warping.referenceCount,
                 Date().timeIntervalSince(started)))

    // The plan's timeline, quarters against reference seconds, for starting or jumping to a bar
    let timeline = try options["timeline"].map { path in
        let cells = try readRows(path)
        return ReferenceTimeline(quarters: cells.map { $0[0] }, seconds: cells.map { $0[1] })
    }

    let following: Following = choice ?? follower
    let begin = { (seconds: Double) in
        if let choice { choice.begin(atReferenceSeconds: seconds) } else { follower.begin(atReferenceSeconds: seconds) }
    }
    var finished: Bool { choice?.isFinished ?? follower.isFinished }

    // Told where the pianist is starting, e.g. "I'll begin at bar 40"
    if let start = options["start-quarters"].flatMap(Double.init), let timeline {
        begin(timeline.seconds(atQuarters: start))
        print(String(format: "starting at quarter %.2f (reference %.2f s)", start, timeline.seconds(atQuarters: start)))
    }

    // Pad to a whole number of hops, as Matchmaker does
    var samples = performance.samples
    let remainder = samples.count % extractor.hopLength
    if remainder > 0 { samples += [Float](repeating: 0, count: extractor.hopLength - remainder) }

    // Simulates the pianist tapping "jump to bar ..." part way through
    let jumpAt = options["jump-at"].flatMap(Double.init)
    let jumpTo = options["jump-quarters"].flatMap(Double.init)
    var jumped = false

    started = Date()
    var inputFeatures: [Float] = [], positions: [Double] = [], diagnostics: [Double] = [], gate: [Double] = []
    var recovery: [Double] = []
    var offset = 0
    // Whether this machine keeps up with live input: hops are followed one after another, so a hop
    // slower than the audio it holds leaves the rest waiting
    let hopSeconds = Double(extractor.hopLength) / extractor.sampleRate
    var slowestHop = 0.0, backlog = 0.0, worstBacklog = 0.0, worstBacklogAt = 0.0, overBudget = 0
    while offset < samples.count && !finished {
        let hopStarted = DispatchTime.now().uptimeNanoseconds
        defer {
            let took = Double(DispatchTime.now().uptimeNanoseconds - hopStarted) / 1e9
            slowestHop = max(slowestHop, took)
            if took > hopSeconds { overBudget += 1 }
            backlog = max(0, backlog + took - hopSeconds)
            if backlog > worstBacklog { worstBacklog = backlog; worstBacklogAt = Double(offset) / extractor.sampleRate }
        }
        if let at = jumpAt, let to = jumpTo, let timeline, !jumped,
           Double(offset) / extractor.sampleRate >= at {
            begin(timeline.seconds(atQuarters: to))
            jumped = true
        }
        if let position = following.process(samples[offset..<(offset + extractor.hopLength)]) {
            inputFeatures += position.features
            positions += [position.time, position.reference]
            diagnostics += [position.time, position.reference, Double(position.confidence),
                            position.silent ? 1 : 0, position.relocated ? 1 : 0]
            gate += [position.time, Double(position.level), Double(position.peakiness)]
            recovery += [Double(position.relocation.rawValue), Double(position.state.rawValue),
                         position.accepted, position.anchor, Double(position.cost)]
        }
        offset += extractor.hopLength
    }
    let stats = choice?.active.follower ?? follower
    if let choice {
        print(choice.chosen.map { String(format: "chose the member at %g of the tempo at %.1f s",
                                                choice.members[$0].rate, choice.chosenAt ?? 0) }
              ?? "never chose a tempo")
    }
    if let heard = stats.calibration {
        print(String(format: "heard the room for %.1f s: %.1f dB, peakiness %.2f -> gate %.2f",
                     heard.seconds, 20 * log10(Double(max(heard.level, 1e-9))), Double(heard.peakiness),
                     Double(heard.gate)) + (heard.tooNoisy ? " (TOO NOISY to follow reliably)" : ""))
    } else {
        print("never heard the room: the gate stayed where it was set")
    }
    let elapsed = Date().timeIntervalSince(started)
    let frames = positions.count / 2
    print(String(format: "followed %d frames in %.2f s (%.3f ms per frame), searches %d, relocations %d, "
                 + "local moves %d, frozen %d frames, picked up after %d rests, candidates %d, rejected %d",
                 frames, elapsed, elapsed / Double(max(frames, 1)) * 1000, stats.searches,
                 stats.relocations, stats.localMoves, stats.frozenFrames, stats.reanchors,
                 stats.candidates, stats.rejections))
    print(String(format: "slowest hop %.1f ms (%.1f ms of audio), %d hops slower than their audio, "
                 + "worst backlog %.2f s at %.1f s", slowestHop * 1000, hopSeconds * 1000, overBudget,
                 worstBacklog, worstBacklogAt))

    if !referenceAudio.isEmpty {
        try write(extractor.chromagram(of: referenceAudio).flatMap { $0 }, to: out.appendingPathComponent("reference_features.f32"))
    }
    try write(inputFeatures, to: out.appendingPathComponent("input_features.f32"))
    try write(positions, to: out.appendingPathComponent("positions.f64"))
    try write(diagnostics, to: out.appendingPathComponent("diagnostics.f64"))
    try write(gate, to: out.appendingPathComponent("gate.f64"))
    try write(recovery, to: out.appendingPathComponent("recovery.f64"))
} catch {
    fail("\(error)")
}
