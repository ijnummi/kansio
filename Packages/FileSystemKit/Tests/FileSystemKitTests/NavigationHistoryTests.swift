import Foundation
import Testing
@testable import FileSystemKit

@Suite("Navigation history")
struct NavigationHistoryTests {
    let a = URL(filePath: "/a", directoryHint: .isDirectory)
    let b = URL(filePath: "/a/b", directoryHint: .isDirectory)
    let c = URL(filePath: "/a/b/c", directoryHint: .isDirectory)
    let d = URL(filePath: "/d", directoryHint: .isDirectory)

    @Test func backAndForward() {
        var h = NavigationHistory(start: a)
        #expect(!h.canGoBack && !h.canGoForward)
        h.visit(b)
        h.visit(c)
        #expect(h.goBack()?.url == b)
        #expect(h.goBack()?.url == a)
        #expect(h.goBack() == nil)
        #expect(h.canGoForward)
        #expect(h.goForward()?.url == b)
        #expect(h.goForward()?.url == c)
        #expect(h.goForward() == nil)
    }

    @Test func visitingClearsForward() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        _ = h.goBack()
        h.visit(d)
        #expect(!h.canGoForward)
        #expect(h.back.map(\.url) == [a, b])
        #expect(h.current.url == d)
    }

    @Test func revisitingCurrentIsNoOp() {
        var h = NavigationHistory(start: a)
        #expect(h.visit(URL(filePath: "/a/", directoryHint: .isDirectory)) == false)
        #expect(h.visit(URL(filePath: "/a")) == false)
        #expect(!h.canGoBack)
    }

    @Test func multiStepJumps() {
        var h = NavigationHistory(start: a)
        h.visit(b); h.visit(c); h.visit(d)
        #expect(h.goBack(3)?.url == a)
        #expect(h.forward.map(\.url) == [b, c, d])
        #expect(h.goForward(2)?.url == c)
        #expect(h.goBack(4) == nil)
        #expect(h.current.url == c)
    }

    @Test func selectionIsRememberedPerEntry() {
        var h = NavigationHistory(start: a)
        h.setCurrentSelection(["b"])        // selected "b" in /a, then opened it
        h.visit(b)
        h.setCurrentSelection(["c", "x"])
        h.visit(c)
        #expect(h.goBack()?.selection == ["c", "x"])
        #expect(h.goBack()?.selection == ["b"])
    }

    @Test func isBounded() {
        var h = NavigationHistory(start: a, limit: 3)
        for i in 0..<10 { h.visit(URL(filePath: "/n\(i)")) }
        #expect(h.back.count == 3)
        #expect(h.back.first?.url.path == "/n6")
    }

    @Test func removeEntriesForEjectedVolume() {
        var h = NavigationHistory(start: a)
        h.visit(URL(filePath: "/Volumes/Stick/x")); h.visit(b); h.visit(URL(filePath: "/Volumes/Stick")); h.visit(c)
        h.removeAll { $0.path.hasPrefix("/Volumes/Stick") }
        #expect(h.back.map(\.url) == [a, b])
    }

    @Test func parent() {
        #expect(parentLocation(of: c)?.parent.path(percentEncoded: false) == "/a/b/")
        #expect(parentLocation(of: c)?.childName == "c")
        #expect(parentLocation(of: URL(filePath: "/a/b/c/", directoryHint: .isDirectory))?.childName == "c")
        #expect(parentLocation(of: a)?.parent.path(percentEncoded: false) == "/")
        #expect(parentLocation(of: URL(filePath: "/")) == nil)
    }
}
