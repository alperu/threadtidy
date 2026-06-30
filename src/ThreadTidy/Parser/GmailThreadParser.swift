import Foundation

// Adapter wrapping the existing ThreadParser (Gmail heuristic) in the
// shared ThreadParsing protocol. Lets Pipeline dispatch uniformly
// across formats. The real Gmail parsing logic lives in
// ThreadParser.swift unchanged.
public struct GmailThreadParser: ThreadParsing {
    public init() {}

    public func parse(lines: [StyledLine]) throws -> Thread {
        ThreadParser().parse(tokens: lines)
    }
}
