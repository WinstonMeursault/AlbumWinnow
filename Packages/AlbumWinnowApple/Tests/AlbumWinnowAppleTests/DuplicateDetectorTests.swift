import AlbumWinnowApple
import Foundation
import Testing

private let fixtures = TestFiles.fixtures

@Test(arguments: [
    ("scene.png", "scene-small.jpg", DuplicateMatch.visualDuplicate),
    ("scene.png", "scene-small.heic", DuplicateMatch.visualDuplicate),
    ("landscape.jpg", "landscape-small.png", DuplicateMatch.visualDuplicate),
    ("burst-a.png", "burst-a.png", DuplicateMatch.exactDuplicate),
    ("burst-a.png", "pixel-copy.png", DuplicateMatch.visualDuplicate),
    ("burst-a.png", "pixel-copy.tiff", DuplicateMatch.visualDuplicate),
    ("burst-a.png", "orientation.png", DuplicateMatch.visualDuplicate),
    ("burst-a.png", "burst-b.png", DuplicateMatch.distinct),
    ("flat-a.png", "flat-b.png", DuplicateMatch.distinct),
])
func classifiesLabeledPair(first: String, second: String, expected: DuplicateMatch) throws {
    let a = try Data(contentsOf: fixtures.appending(path: first))
    let b = try Data(contentsOf: fixtures.appending(path: second))
    #expect(try DuplicateDetector().compare(a, b) == expected)
    #expect(try DuplicateDetector().compare(b, a) == expected)
}

@Test func reportsMalformedInput() throws {
    let broken = try Data(contentsOf: fixtures.appending(path: "unreadable.png"))
    #expect(throws: ImageReadError.unreadableImage) {
        try DuplicateDetector().compare(broken, broken)
    }
}
