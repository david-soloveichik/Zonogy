/// Determines which resize axes are allowed for placeholder windows based on zone layout
struct PlaceholderResizePolicy {
    static func allowedAxes(zoneIndex: Int, zoneCount: Int, zoneIsEmpty: Bool) -> PlaceholderResizeAxes {
        guard zoneIsEmpty else {
            return []
        }

        switch zoneCount {
        case 0, 1:
            return []
        case 2:
            return [.horizontal]
        case 3:
            if zoneIndex == 1 {
                return [.horizontal]
            } else {
                return [.horizontal, .vertical]
            }
        default:
            return []
        }
    }
}
