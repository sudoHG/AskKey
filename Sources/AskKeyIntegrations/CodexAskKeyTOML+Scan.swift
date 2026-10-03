import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    enum Scan: Equatable {
        case normal
        case basicML(brackets: Int, braces: Int)
        case literalML(brackets: Int, braces: Int)
        case collections(brackets: Int, braces: Int)

        var isNormal: Bool {
            if case .normal = self { return true }
            return false
        }
    }
}
