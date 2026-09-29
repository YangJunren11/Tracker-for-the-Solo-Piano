import Foundation

/// Reads a MusicXML file (.musicxml, .xml or compressed .mxl) into a `ScoreData`.
///
/// What a follower needs from a score is where each note falls, in quarter notes, and which bar it
/// falls in; the printed bar numbers on top of that, so a place can be named by one. So that is what
/// this reads, from every part in the file: a piano score is written either as one part of two
/// staves or as two parts of one staff each, and reading only the first would lose a hand.
public enum MusicXMLReader {
    public enum Failure: LocalizedError {
        case notMusicXML
        case noBars
        case noNotes
        case unreadableArchive
        case noScoreInZip
        case isPDF
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notMusicXML: return "That file is not MusicXML."
            case .noBars: return "That file has no bars in it."
            case .noNotes: return "That file has no notes in it, so there is nothing to follow."
            case .unreadableArchive: return "That .mxl file could not be opened."
            case .noScoreInZip: return "That zip file has no MusicXML score in it."
            case .isPDF: return "That is a PDF. Pick the MusicXML file (.mxl or .musicxml) here; the PDF is asked for next."
            case .tooLarge: return "That file is far too large to be a score."
            }
        }
    }

    /// Larger than any score: the file picker offers every file, so this is what keeps a video
    /// picked by mistake from being read into memory whole.
    static let largestFile = 100_000_000

    /// A score read from a file, before the pianist has said what it is.
    ///
    /// The title, composer and tempo marking a file carries are suggestions rather than facts —
    /// MusicXML files are often untitled, or titled by whoever typed them in — so they come back
    /// separately for the pianist to confirm or correct.
    public struct Draft {
        public let suggestedTitle: String
        public let suggestedComposer: String
        public let suggestedTempo: String?
        public let bars: [ScoreData.Bar]
        public let repeats: [ScoreData.Repeat]
        public let jumps: [ScoreData.Jump]
        public let tempos: [[Double]]
        public let notes: [ScoreData.Note]
        /// Where the printed bar numbers start again, which is where one movement gives way to the next.
        public let movementStarts: [Int]

        public var barCount: Int { bars.count }
        public var noteCount: Int { notes.count }

        /// The score, once it has been named.
        ///
        /// A file holding several movements is stored as a work in parts, exactly as the database
        /// stores one, because the printed bar numbers start again at each: without that "bar 1"
        /// would be ambiguous.
        public func score(title: String, composer: String, tempo: String?) -> ScoreData {
            let named = tempo?.trimmingCharacters(in: .whitespacesAndNewlines)
            let marking = (named?.isEmpty ?? true) ? nil : named
            var parts: [ScoreData.Part] = []
            if movementStarts.count > 1 {
                for (index, first) in movementStarts.enumerated() {
                    let numeral = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"]
                    parts.append(ScoreData.Part(name: index < numeral.count ? numeral[index] : "\(index + 1)",
                                                firstBar: first,
                                                tempo: index == 0 ? marking : nil))
                }
            } else if let marking {
                parts.append(ScoreData.Part(name: "", firstBar: 0, tempo: marking))
            }
            return ScoreData(title: title, composer: composer, movements: nil, parts: parts,
                             bars: bars, repeats: repeats, jumps: jumps, tempos: tempos, notes: notes)
        }
    }

    public static func read(contentsOf url: URL) throws -> Draft {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > largestFile {
            throw Failure.tooLarge
        }
        return try read(try Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> Draft {
        let xml = try document(from: data)
        guard let root = try? XMLLite.parse(xml) else { throw Failure.notMusicXML }
        let parts = root.descendants("part").filter { part in
            part.children.contains { $0.name == "measure" }
        }
        guard let first = parts.first else { throw Failure.notMusicXML }
        guard first.children.contains(where: { $0.name == "measure" }) else { throw Failure.noBars }
        let draft = build(root: root, parts: parts)
        // Bars but no notes: a file of rests, or one whose notes are written somewhere this does
        // not look. Either way the follower would have nothing to listen for, and a score saved
        // like that can never be played from, so it is refused here rather than in the library.
        guard !draft.notes.isEmpty else { throw Failure.noNotes }
        return draft
    }

    /// The MusicXML itself, unwrapped from a compressed .mxl container when it is one, or from an
    /// ordinary zip holding one: a score downloaded as "Sonata.mxl.zip", or zipped to send, arrives
    /// that way.
    private static func document(from data: Data, inZip: Bool = false) throws -> Data {
        if data.starts(with: Array("%PDF".utf8)) { throw Failure.isPDF }
        guard data.count > 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B else {
            return data  // not a zip, so already plain MusicXML
        }
        let archive = try Zip(data)
        // The container names the file to read; MusicXML says so, and the name varies
        if let container = try? archive.file(named: "META-INF/container.xml") {
            guard let node = try? XMLLite.parse(container),
                  let path = node.descendants("rootfile").first?.attributes["full-path"],
                  let score = try? archive.file(named: path) else { throw Failure.unreadableArchive }
            return score
        }
        // An ordinary zip: the score in it, an .mxl before the others, and a zip inside a zip no
        // further. The resource entries some zip tools add (__MACOSX/, and a "._" file beside each) are
        // not scores.
        guard !inZip else { throw Failure.unreadableArchive }
        let names = archive.names.sorted().filter { name in
            let file = name.split(separator: "/").last.map(String.init) ?? name
            return !name.hasPrefix("__MACOSX/") && !file.hasPrefix("._")
        }
        for suffix in [".mxl", ".musicxml", ".xml"] {
            if let name = names.first(where: { $0.lowercased().hasSuffix(suffix) }) {
                return try document(from: try archive.file(named: name), inZip: true)
            }
        }
        throw Failure.noScoreInZip
    }

    // MARK: - Reading the measures

    /// A piano score can be written as one part of two staves or as two parts of one staff each —
    /// MuseScore exports the second way. The bars come from the first part; the notes come from
    /// every part, or one hand would go missing.
    private static func build(root: XMLLite.Node, parts: [XMLLite.Node]) -> Draft {
        let measures = parts[0].children.filter { $0.name == "measure" }
        var bars: [ScoreData.Bar] = []
        var tempos: [[Double]] = []
        var movementStarts: [Int] = [0]

        var divisions = 1.0  // divisions per quarter note, from the most recent attributes
        var signature = 4.0  // the notated length of a bar, in quarter notes
        var start = 0.0
        var number = 0
        var previousNumber: Int?

        for (index, measure) in measures.enumerated() {
            if let value = measure.first("attributes")?.firstText("divisions").flatMap(Double.init), value > 0 {
                divisions = value
            }
            if let time = measure.first("attributes")?.first("time"),
               let beats = time.firstText("beats").flatMap(Double.init),
               let unit = time.firstText("beat-type").flatMap(Double.init), unit > 0 {
                signature = beats * 4 / unit
            }
            let label = measure.attributes["number"] ?? ""
            if let digits = leadingInt(label) { number = digits }
            // A bar number that starts again is a new movement: the fugue has its own bar 1
            if let previous = previousNumber, number < previous, index > 0 {
                movementStarts.append(index)
            }
            previousNumber = number

            var ignored: [ScoreData.Note] = []
            var unused: [String: [Int]] = [:]
            let played = read(measure: measure, divisions: divisions, barStart: start, bar: index,
                              pending: &unused, into: &ignored)
            // A bar is as long as what is written in it, not as long as the time signature says: a
            // pickup bar is shorter, a fugue's last bar can be a single quarter in 3/8, and a score
            // that writes more into a bar than the signature allows means it. Only an empty bar
            // falls back on the signature.
            let duration = played > 0 ? played : signature
            bars.append(ScoreData.Bar(label: label, number: number, start: start, duration: duration))
            start += duration

            for sound in measure.descendants("sound") {
                if let bpm = sound.attributes["tempo"].flatMap(Double.init), bpm > 0,
                   tempos.last?.last != bpm {
                    tempos.append([Double(index), bpm])
                }
            }
        }

        var notes: [ScoreData.Note] = []
        for part in parts {
            var mine: [ScoreData.Note] = []  // a tie belongs to its own part, so each is read alone
            var pending: [String: [Int]] = [:]
            var divisions = 1.0
            for (index, measure) in part.children.filter({ $0.name == "measure" }).enumerated() {
                guard index < bars.count else { break }
                if let value = measure.first("attributes")?.firstText("divisions").flatMap(Double.init),
                   value > 0 {
                    divisions = value
                }
                _ = read(measure: measure, divisions: divisions, barStart: bars[index].start,
                         bar: index, pending: &pending, into: &mine)
            }
            notes += mine
        }
        // Which bar a note falls in is decided by where it sounds, not by the measure it was
        // written in: a voice that begins after a backup can run past the end of its own bar.
        let starts = bars.map(\.start)
        notes = notes.map { note in
            ScoreData.Note(onset: note.onset, duration: note.duration, pitch: note.pitch,
                           bar: bar(of: note.onset, in: starts))
        }
        notes.sort { ($0.bar, $0.onset, $0.pitch) < ($1.bar, $1.onset, $1.pitch) }

        let (repeats, jumps) = structure(of: measures)
        return Draft(suggestedTitle: title(of: root), suggestedComposer: composer(of: root),
                     suggestedTempo: marking(in: measures, root: root),
                     bars: bars, repeats: repeats, jumps: jumps, tempos: tempos, notes: notes,
                     movementStarts: movementStarts)
    }

    /// The last bar that has begun by this point in the score.
    private static func bar(of onset: Double, in starts: [Double]) -> Int {
        var low = 0, high = starts.count - 1, found = 0
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= onset + 1e-6 {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// Walks one measure, adding the notes it holds. Returns how far its voices reached, in
    /// quarter notes, which is how long the bar is.
    ///
    /// MusicXML is written voice by voice: `backup` winds the clock back so the next voice can be
    /// written, which is why the notes of a two-staff piano bar arrive one voice after another
    /// rather than in time order.
    private static func read(measure: XMLLite.Node, divisions: Double, barStart: Double, bar: Int,
                             pending: inout [String: [Int]],
                             into notes: inout [ScoreData.Note]) -> Double {
        var cursor = 0.0
        var reached = 0.0
        var previousOnset = 0.0  // where the last note began, for the notes of a chord
        for element in measure.children {
            switch element.name {
            case "backup":
                cursor -= (element.firstText("duration").flatMap(Double.init) ?? 0) / divisions
            case "forward":
                // Used to pad a voice out with nothing, so it can reach past the last note written
                cursor += (element.firstText("duration").flatMap(Double.init) ?? 0) / divisions
                reached = max(reached, cursor)
            case "note":
                let length = (element.firstText("duration").flatMap(Double.init) ?? 0) / divisions
                let isChord = element.first("chord") != nil
                let isGrace = element.first("grace") != nil
                let onset = isChord ? previousOnset : cursor
                if let pitch = element.first("pitch"), let midi = midiNote(pitch) {
                    // A tied note is one note held: what it ties to lengthens it rather than
                    // sounding again, because an onset the pianist never plays is an onset the
                    // follower would listen for in vain. MusicXML says which note continues which
                    // by voice and pitch, so that is how they are paired — a tie crosses bar lines,
                    // and the same pitch can be tied in one hand while struck in the other.
                    let ties = Set(element.all("tie").compactMap { $0.attributes["type"] })
                    let voice = element.firstText("voice") ?? ""
                    let held = "\(voice)|\(midi)"
                    // The note it continues has to end where this one begins. A tie left open by
                    // the engraving would otherwise still be waiting many bars later and swallow an
                    // unrelated note of the same pitch. There can be more than one waiting — a
                    // chord can hold the same pitch in two places — so the one that ends here is
                    // the one taken.
                    let waiting = pending[held] ?? []
                    let previous = waiting.last {
                        $0 < notes.count
                            && abs(notes[$0].onset + notes[$0].duration - (barStart + onset)) < 1e-6
                    }
                    if ties.contains("stop"), let previous {
                        let sounded = notes[previous]
                        notes[previous] = ScoreData.Note(onset: sounded.onset,
                                                         duration: sounded.duration + length,
                                                         pitch: sounded.pitch, bar: sounded.bar)
                        pending[held] = waiting.filter { $0 != previous }
                        if ties.contains("start") { pending[held, default: []].append(previous) }
                    } else if !ties.contains("stop") {
                        notes.append(ScoreData.Note(onset: barStart + onset, duration: length,
                                                    pitch: midi, bar: bar))
                        if ties.contains("start") { pending[held, default: []].append(notes.count - 1) }
                    }
                }
                if !isChord { previousOnset = cursor }
                if !isGrace, !isChord { cursor += length }
                reached = max(reached, cursor)
            default:
                break
            }
        }
        return max(reached, cursor)
    }

    private static func midiNote(_ pitch: XMLLite.Node) -> Int? {
        let steps = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let step = pitch.firstText("step"), let semitone = steps[step.uppercased()],
              let octave = pitch.firstText("octave").flatMap(Int.init) else { return nil }
        let alter = pitch.firstText("alter").flatMap(Double.init) ?? 0
        return (octave + 1) * 12 + semitone + Int(alter.rounded())
    }

    // MARK: - Repeats and jumps

    /// The repeat structure: repeat signs, endings, and D.C./D.S. with Fine and Coda.
    private static func structure(of measures: [XMLLite.Node]) -> ([ScoreData.Repeat], [ScoreData.Jump]) {
        var forwards: [Int] = []
        var backwards: [(end: Int, times: Int)] = []
        var endings: [(passes: [Int], first: Int, last: Int)] = []
        var open: [String: Int] = [:]
        var marks: [String: Int] = [:]

        for (index, measure) in measures.enumerated() {
            for barline in measure.descendants("barline") {
                if let repeatMark = barline.first("repeat") {
                    if repeatMark.attributes["direction"] == "forward" {
                        forwards.append(index)
                    } else {
                        backwards.append((index, repeatMark.attributes["times"].flatMap(Int.init) ?? 2))
                    }
                }
                for ending in barline.all("ending") {
                    let key = ending.attributes["number"] ?? ""
                    if ending.attributes["type"] == "start" {
                        open[key] = index
                    } else if let first = open.removeValue(forKey: key) {
                        endings.append((passes(key), first, index))
                    }
                }
            }
            for sound in measure.descendants("sound") {
                for attribute in ["segno", "coda", "tocoda", "fine", "dacapo", "dalsegno"] {
                    if let value = sound.attributes[attribute], value != "no", marks[attribute] == nil {
                        marks[attribute] = index
                    }
                }
            }
        }
        for (key, first) in open { endings.append((passes(key), first, first)) }
        endings.sort { $0.first < $1.first }

        var repeats: [ScoreData.Repeat] = []
        var resume = 0
        for (end, times) in backwards {
            if end < resume { continue }  // a later sign inside an ending group already dealt with
            let group = endingGroup(endings, containing: end)
            let bodyEnd = group.first.map { $0.first - 1 } ?? end
            let start = forwards.filter { $0 >= resume && $0 <= bodyEnd }.max() ?? resume
            var mark: ScoreData.Repeat
            if !group.isEmpty {
                let passLists = group.enumerated().map { $1.passes.isEmpty ? [$0 + 1] : $1.passes }
                let total = max(times, passLists.flatMap { $0 }.max() ?? times)
                var perPass: [[Int]] = []
                for pass in 1...total {
                    let found = zip(passLists, group).first { $0.0.contains(pass) }?.1
                    let chosen = found ?? group[group.count - 1]
                    perPass.append([chosen.first, chosen.last])
                }
                mark = ScoreData.Repeat(start: start, end: end, endings: perPass, times: total)
            } else {
                mark = ScoreData.Repeat(start: start, end: end, endings: [], times: times)
            }
            repeats.append(mark)
            resume = (mark.endings.compactMap { $0.last }.max() ?? mark.end) + 1
        }

        var jumps: [ScoreData.Jump] = []
        for (kind, attribute) in [("D.C.", "dacapo"), ("D.S.", "dalsegno")] {
            guard let at = marks[attribute] else { continue }
            let target = kind == "D.C." ? 0 : (marks["segno"] ?? 0)
            jumps.append(ScoreData.Jump(kind: kind, at: at, target: target, fine: marks["fine"],
                                        toCoda: marks["tocoda"], coda: marks["coda"]))
        }
        return (repeats, jumps)
    }

    private static func passes(_ number: String) -> [Int] {
        number.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The run of adjacent endings (1st, 2nd, ...) that contains a bar.
    private static func endingGroup(_ endings: [(passes: [Int], first: Int, last: Int)],
                                    containing bar: Int) -> [(passes: [Int], first: Int, last: Int)] {
        guard let k = endings.firstIndex(where: { $0.first <= bar && bar <= $0.last }) else { return [] }
        var low = k, high = k
        while low > 0, endings[low - 1].last + 1 == endings[low].first { low -= 1 }
        while high + 1 < endings.count, endings[high].last + 1 == endings[high + 1].first { high += 1 }
        return Array(endings[low...high])
    }

    // MARK: - What the file says it is

    private static func title(of root: XMLLite.Node) -> String {
        let work = root.first("work")?.firstText("work-title")
        let movement = root.firstText("movement-title")
        let credit = root.descendants("credit").first { $0.firstText("credit-type") == "title" }?
            .firstText("credit-words")
        for candidate in [work, credit, movement] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 1 {
                return text
            }
        }
        return ""
    }

    private static func composer(of root: XMLLite.Node) -> String {
        let creator = root.descendants("creator").first { $0.attributes["type"] == "composer" }?.text
        let credit = root.descendants("credit").first { $0.firstText("credit-type") == "composer" }?
            .firstText("credit-words")
        for candidate in [creator, credit] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 1 {
                return text
            }
        }
        return ""
    }

    /// The tempo marking to offer, from the directions in the opening bars or the movement's title.
    ///
    /// Offered rather than decided: for a file typed in by anyone at all, the pianist reading the
    /// score is the better judge.
    private static func marking(in measures: [XMLLite.Node], root: XMLLite.Node) -> String? {
        for measure in measures.prefix(3) {
            for words in measure.descendants("words") {
                let text = words.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 2, text.count < 60 { return text }
            }
        }
        if let movement = root.firstText("movement-title")?.trimmingCharacters(in: .whitespacesAndNewlines),
           movement.count > 2, movement.count < 60 {
            return movement
        }
        return nil
    }

    private static func leadingInt(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }
}
