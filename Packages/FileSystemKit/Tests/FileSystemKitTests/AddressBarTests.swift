import Foundation
import Testing
@testable import FileSystemKit

@Suite("Address bar logic")
struct AddressBarTests {
    let base = URL(filePath: "/Users/me/Projects", directoryHint: .isDirectory)
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    func resolve(_ s: String) -> String? {
        PathInput.resolve(s, relativeTo: base, home: home)?.path(percentEncoded: false)
    }

    @Test func resolvesTypedPaths() {
        #expect(resolve("/usr/bin") == "/usr/bin")
        #expect(resolve("/usr/bin/") == "/usr/bin")
        #expect(resolve("~") == "/Users/me")
        #expect(resolve("~/Documents") == "/Users/me/Documents")
        #expect(resolve("kansio") == "/Users/me/Projects/kansio")
        #expect(resolve("../Desktop") == "/Users/me/Desktop")
        #expect(resolve("/a/./b//c/../d") == "/a/b/d")
        #expect(resolve("/..") == "/")
        #expect(resolve("  /tmp  ") == "/tmp")
        #expect(resolve("\"/Users/me/My Folder\"") == "/Users/me/My Folder")
        #expect(resolve("'/tmp/x'") == "/tmp/x")
        #expect(resolve("file:///Users/me/My%20Folder/") == "/Users/me/My Folder")
        #expect(resolve("") == nil)
        #expect(resolve("   ") == nil)
    }

    @Test func tildeUser() {
        let root = PathInput.resolve("~root/x", relativeTo: base, home: home)?.path(percentEncoded: false)
        #expect(root == "/var/root/x")
    }

    @Test func classifiesTargets() async throws {
        let t = try TempDir()
        try t.dir("Folder")
        try t.dir("App.app/Contents")
        let file = try t.file("file.txt")
        try t.symlink("link", to: "Folder")
        #expect(await PathInput.target(of: t.url.appending(path: "Folder")) == .folder)
        #expect(await PathInput.target(of: t.url.appending(path: "link")) == .folder)
        #expect(await PathInput.target(of: t.url.appending(path: "App.app")) == .item)
        #expect(await PathInput.target(of: file) == .item)
        #expect(await PathInput.target(of: t.url.appending(path: "nope")) == .missing)
        #expect(await PathInput.target(of: file.appending(path: "below-a-file")) == .missing)
    }

    @Test func breadcrumbsStartWithTheVolume() {
        let root = Volume(url: URL(filePath: "/", directoryHint: .isDirectory), name: "Macintosh HD",
                          isRoot: true, isInternal: true, isEjectable: false, isNetwork: false)
        let stick = Volume(url: URL(filePath: "/Volumes/Stick", directoryHint: .isDirectory), name: "Stick",
                           isRoot: false, isInternal: false, isEjectable: true, isNetwork: false)
        let crumbs = Breadcrumbs.segments(for: URL(filePath: "/Users/me/Docs"), volumes: [root, stick])
        #expect(crumbs.map(\.title) == ["Macintosh HD", "Users", "me", "Docs"])
        #expect(crumbs.map { $0.url.path(percentEncoded: false) } == ["/", "/Users/", "/Users/me/", "/Users/me/Docs/"])
        let onStick = Breadcrumbs.segments(for: URL(filePath: "/Volumes/Stick/a/"), volumes: [root, stick])
        #expect(onStick.map(\.title) == ["Stick", "a"])
        #expect(onStick.last?.url.path(percentEncoded: false) == "/Volumes/Stick/a/")
        #expect(Breadcrumbs.segments(for: URL(filePath: "/"), volumes: [root]).map(\.title) == ["Macintosh HD"])
        #expect(Breadcrumbs.segments(for: URL(filePath: "/x"), volumes: []).map(\.title) == ["/", "x"])
    }

    @Test func completesFolderNames() async throws {
        let t = try TempDir()
        for name in ["Documents", "Downloads", "desktop-stuff", ".hidden", "Café", "Other"] { try t.dir(name) }
        try t.file("Doc.txt")                 // files are never suggested
        try t.symlink("Docs-link", to: "Documents")
        let completer = PathCompleter()
        let prefix = t.path.hasSuffix("/") ? t.path : t.path + "/"

        let doc = await completer.completions(for: prefix + "do", relativeTo: base, includeHidden: false)
        #expect(doc.map(\.name) == ["Docs-link", "Documents", "Downloads"])
        #expect(doc.first?.text == prefix + "Docs-link/")

        let all = await completer.completions(for: prefix, relativeTo: base, includeHidden: false)
        #expect(!all.map(\.name).contains(".hidden"))
        #expect(all.map(\.name).contains("Café"))
        #expect(await completer.completions(for: prefix + ".h", relativeTo: base, includeHidden: false).map(\.name) == [".hidden"])
        // NFD typed prefix matches an NFC name, accents optional
        #expect(await completer.completions(for: prefix + "Cafe\u{0301}", relativeTo: base, includeHidden: false).map(\.name) == ["Café"])
        #expect(await completer.completions(for: prefix + "cafe", relativeTo: base, includeHidden: false).map(\.name) == ["Café"])
        // relative input keeps the typed form
        let relative = await completer.completions(for: "Ot", relativeTo: t.url, includeHidden: false)
        #expect(relative == [PathCompletion(name: "Other", text: "Other/")])
        // missing folder: no suggestions, no error
        #expect(await completer.completions(for: prefix + "nope/x", relativeTo: base, includeHidden: false).isEmpty)
    }

    @Test func tildeCompletionKeepsTilde() async throws {
        let t = try TempDir()
        try t.dir("Music")
        let completer = PathCompleter()
        let result = await completer.completions(for: "~/Mu", relativeTo: base, includeHidden: false, home: t.url)
        #expect(result == [PathCompletion(name: "Music", text: "~/Music/")])
    }
}
