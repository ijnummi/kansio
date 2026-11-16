import Foundation
import Testing
@testable import FileSystemKit

@Suite("Volumes")
struct VolumeTests {
    @Test func startupDiskIsListedFirst() async {
        let volumes = await VolumeList.mountedVolumes()
        let first = volumes.first
        #expect(first?.isRoot == true)
        #expect(first?.url.path(percentEncoded: false) == "/")
        #expect(volumes.filter(\.isRoot).count == 1)
        #expect(volumes.allSatisfy { !$0.name.isEmpty })
    }

    @Test func containsPath() {
        let v = Volume(url: URL(filePath: "/Volumes/Stick", directoryHint: .isDirectory), name: "Stick",
                       isRoot: false, isInternal: false, isEjectable: true, isNetwork: false)
        #expect(v.contains(path: "/Volumes/Stick"))
        #expect(v.contains(path: "/Volumes/Stick/"))
        #expect(v.contains(path: "/Volumes/Stick/a/b"))
        #expect(!v.contains(path: "/Volumes/Sticky"))
        #expect(!v.contains(path: "/Users"))
    }
}
