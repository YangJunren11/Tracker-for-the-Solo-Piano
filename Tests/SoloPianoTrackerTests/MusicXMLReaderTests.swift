import XCTest
@testable import SoloPianoTracker

#if os(macOS) || os(Linux)
/// The ways a score arrives: plain, compressed (.mxl), and inside an ordinary zip. The zips are made
/// by `zip`; the `__MACOSX` and `._` entries some zip tools add are made by hand beside the score.
final class MusicXMLReaderTests: XCTestCase {
    private let score = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
              <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
            </measure>
          </part>
        </score-partwise>
        """
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes `files` (path: contents) into a folder of its own and zips them as `name`.
    private func zip(_ name: String, _ files: [String: Data]) throws -> URL {
        let staging = folder.appendingPathComponent(UUID().uuidString)
        for (path, contents) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        let target = folder.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"), "needs /usr/bin/zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-qr", target.path] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return target
    }

    private func mxl(_ name: String = "Sonata.mxl") throws -> URL {
        let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container><rootfiles><rootfile full-path="Sonata.musicxml"/></rootfiles></container>
            """
        return try zip(name, ["META-INF/container.xml": Data(container.utf8), "Sonata.musicxml": Data(score.utf8)])
    }

    private func notes(_ url: URL) throws -> Int {
        try MusicXMLReader.read(contentsOf: url).notes.count
    }

    func testPlainAndCompressed() throws {
        let plain = folder.appendingPathComponent("Sonata.musicxml")
        try Data(score.utf8).write(to: plain)
        XCTAssertEqual(try notes(plain), 1)
        XCTAssertEqual(try notes(try mxl()), 1)
        // Only the name changed, as a download can do
        XCTAssertEqual(try notes(try mxl("Sonata.mxl.zip")), 1)
    }

    func testZipHoldingAScore() throws {
        let inner = try Data(contentsOf: try mxl())
        let resource = Data([0, 5, 22, 7, 0, 2, 0, 0])  // a resource-fork header, not a score
        let wrapped = try zip("Sonata.zip", ["__MACOSX/._Sonata.mxl": resource, "._Sonata.mxl": resource,
                                             "Sonata.mxl": inner, "notes.txt": Data("hello".utf8)])
        XCTAssertEqual(try notes(wrapped), 1)
        let loose = try zip("Loose.zip", ["scores/Sonata.musicxml": Data(score.utf8)])
        XCTAssertEqual(try notes(loose), 1)
    }

    func testWhatIsNotAScoreSaysSo() throws {
        let empty = try zip("Photos.zip", ["photo.jpg": Data([0xFF, 0xD8, 0xFF])])
        XCTAssertThrowsError(try notes(empty)) { XCTAssertEqual($0 as? MusicXMLReader.Failure, .noScoreInZip) }
        let pdf = folder.appendingPathComponent("Sonata.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdf)
        XCTAssertThrowsError(try notes(pdf)) { XCTAssertEqual($0 as? MusicXMLReader.Failure, .isPDF) }
    }
}
#endif
