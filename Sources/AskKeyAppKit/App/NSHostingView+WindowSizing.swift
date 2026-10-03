import SwiftUI

extension NSHostingView: HostingWindowSizing {
    func stopResizingWindowFromContent() {
        sizingOptions = []
    }
}
