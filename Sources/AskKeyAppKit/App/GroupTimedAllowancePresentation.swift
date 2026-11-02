import Foundation
import Observation
import AskKeyBroker

/// The live card can withdraw only its group option while preserving its request.
@Observable
final class GroupTimedAllowancePresentation {
    var snapshot: BrokerGroupAllowanceSnapshot?

    init(snapshot: BrokerGroupAllowanceSnapshot?) { self.snapshot = snapshot }
}
