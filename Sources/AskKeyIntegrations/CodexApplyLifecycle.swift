import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

struct CodexApplyLifecycle {
    var afterBackup: () throws -> Void = {}
    var afterWrite: () throws -> Void = {}
    var beforeRestore: () throws -> Void = {}
}
