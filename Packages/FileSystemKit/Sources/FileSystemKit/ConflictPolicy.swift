import Foundation

/// Asks about each conflict once — unless the user ticked "apply to all", after which the same
/// answer is reused for every later conflict *of the same kind* in this operation. Folder-onto-
/// folder clashes and file clashes are remembered separately, so "Replace all" for files never
/// silently replaces whole folders.
public actor ConflictPolicy {
    public typealias Ask = @Sendable (Conflict) async -> (resolution: ConflictResolution, applyToAll: Bool)

    enum Category: Hashable { case folders, other }

    private let ask: Ask
    private var remembered: [Category: ConflictResolution] = [:]
    private(set) var questionsAsked = 0

    public init(ask: @escaping Ask) { self.ask = ask }

    public func resolve(_ conflict: Conflict) async -> ConflictResolution {
        let category: Category = conflict.sourceIsFolder && conflict.existingIsFolder ? .folders : .other
        if let answer = remembered[category] { return answer }
        questionsAsked += 1
        let (resolution, applyToAll) = await ask(conflict)
        if applyToAll && resolution != .stop { remembered[category] = resolution }
        return resolution
    }

    /// The resolver to hand to `CopyEngine`.
    public nonisolated var resolver: CopyEngine.Resolver { { [self] conflict in await self.resolve(conflict) } }
}
