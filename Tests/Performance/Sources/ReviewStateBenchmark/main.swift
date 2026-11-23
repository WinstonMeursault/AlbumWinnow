import AlbumWinnowCore
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func milliseconds(_ action: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock(), start = ContinuousClock.now
    try action()
    let duration = start.duration(to: clock.now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
var results: [[String: Any]] = []
for count in [100, 1_000, 10_000] {
    let url = root.appending(path: "\(UUID()).sqlite")
    let store = try ReviewStateStore(url: url)
    var state = ReviewState()
    for i in 0..<count {
        let a = PhotoAsset(id: AssetID(source: "folder:/fixture/photos", item: "/fixture/photos/\(i)-a.jpg"), name: "\(i)-a.jpg", revision: "1:2:10485760:100:0:100:0", byteCount: 10485760)
        let b = PhotoAsset(id: AssetID(source: "folder:/fixture/photos", item: "/fixture/photos/\(i)-b.jpg"), name: "\(i)-b.jpg", revision: "1:3:10485760:100:0:100:0", byteCount: 10485760)
        state.decisions[String(i)] = ReviewDecision(status: .confirmed, keepID: a.id, removals: [b.id], members: [a, b])
    }
    try store.save(state)
    var positions: [Double] = [], decisions: [Double] = []
    for i in 0..<5 {
        positions.append(try milliseconds { try store.savePosition(anchor: String(i), index: i) })
        state.anchor = String(i); state.anchorIndex = i
        var next = state
        next.decisions[String(i)]?.status = .deferred
        decisions.append(try milliseconds { try store.save(next, replacing: state) })
        state = next
    }
    let loaded = try store.load()
    precondition(loaded == state)
    results.append(["groups": count, "positionMilliseconds": positions, "decisionMilliseconds": decisions])
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
