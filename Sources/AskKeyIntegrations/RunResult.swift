import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

struct RunResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}