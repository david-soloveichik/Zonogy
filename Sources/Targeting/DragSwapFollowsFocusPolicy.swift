/// Pure selection logic for immediate follows-focus retargeting after a tiled window exchange.
import Foundation

enum DragSwapFollowsFocusPolicy {
    static func targetAfterExchange(
        targetingMode: TargetingMode,
        sourceKey: ZoneKey?,
        targetKey: ZoneKey,
        displacedWindowId: Int?
    ) -> ZoneKey? {
        guard targetingMode == .followsFocus,
              sourceKey != nil,
              displacedWindowId != nil else {
            return nil
        }

        // In a tiled-to-tiled exchange, the dragged window remains the active window,
        // so follows-focus should immediately target its new zone.
        return targetKey
    }
}
