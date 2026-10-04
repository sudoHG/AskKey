import Foundation
import SwiftUI

/// Fills a localized format whose arguments are `%1$@`, `%2$@`… (or `%@`)
/// and keeps track of which runs came from arguments, so names can be
/// emphasized in any language's word order.
struct EmphasizedSentence: Equatable {
    struct Run: Equatable {
        let text: String
        /// The zero-based argument this run came from; nil for literal text.
        let argument: Int?

        var isArgument: Bool { argument != nil }
    }

    let runs: [Run]

    init(format: String, arguments: [String]) {
        var runs: [Run] = []
        var literal = ""
        var nextSequential = 0
        var index = format.startIndex
        while index < format.endIndex {
            guard format[index] == "%" else {
                literal.append(format[index])
                index = format.index(after: index)
                continue
            }
            let rest = format[format.index(after: index)...]
            if rest.hasPrefix("%") {
                literal.append("%")
                index = format.index(index, offsetBy: 2)
                continue
            }
            var position: Int?
            var length = 0
            if rest.hasPrefix("@") {
                position = nextSequential
                nextSequential += 1
                length = 1
            } else if let dollar = rest.firstIndex(of: "$"),
                      let number = Int(rest[rest.startIndex..<dollar]),
                      rest[rest.index(after: dollar)...].hasPrefix("@") {
                position = number - 1
                length = rest.distance(from: rest.startIndex, to: dollar) + 2
            }
            guard let position, arguments.indices.contains(position) else {
                literal.append("%")
                index = format.index(after: index)
                continue
            }
            if !literal.isEmpty {
                runs.append(.init(text: literal, argument: nil))
                literal = ""
            }
            runs.append(.init(text: arguments[position], argument: position))
            index = format.index(index, offsetBy: length + 1)
        }
        if !literal.isEmpty { runs.append(.init(text: literal, argument: nil)) }
        self.runs = runs
    }

    var plainText: String { runs.map(\.text).joined() }

    /// Styles each argument with the font at its position; arguments past
    /// the end of `argumentFonts` keep the surrounding font.
    func attributed(argumentFonts: [Font]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var part = AttributedString(run.text)
            if let argument = run.argument, argumentFonts.indices.contains(argument) {
                part.font = argumentFonts[argument]
            }
            result += part
        }
    }
}
