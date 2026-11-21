import LilyKit
import Foundation

/// `Space` is LilyKit's (shared with Lily-ios). The Mac kept calling the color `color`; this keeps that name.
extension Space {
    var color: String {
        get { colorHex }
        set { colorHex = newValue }
    }

    init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", color: String = "#5B4CF5") {
        self.init(id: id, name: name, symbol: symbol, colorHex: color)
    }
}

extension Tab {
    /// The platform-neutral view of this tab (LilyKit's `TabModel`): what lists, sessions and the sleep policy work on.
    func model(splitID: UUID? = nil) -> TabModel {
        TabModel(id: id, spaceID: spaceID, url: url, title: title, isPinned: isPinned, splitID: splitID,
                 isSleeping: isSleeping, lastActivated: lastActivated)
    }
}
