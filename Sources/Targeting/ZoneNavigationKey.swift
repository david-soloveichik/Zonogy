/// The vocabulary of zone-navigation selection keys: what one press asks of the gesture.
///
/// The arrow keys step the blue circle one zone at a time (`ZoneNavigationDirection`); the letter
/// keys jump — A/S/D/F to a cell of the current screen's two-by-two zone grid, G to its floating
/// zone, and J/K/L to a display. Which physical keys carry these meanings, and which groups are
/// enabled, is `ZoneNavigationKeyGroups`.

/// The four arrow directions of zone navigation.
enum ZoneNavigationDirection: Equatable {
    case up
    case down
    case left
    case right

    /// The reverse direction; a press in this direction backs zone navigation's trail out of its
    /// last move.
    var opposite: ZoneNavigationDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

/// A cell of the two-by-two grid a screen's tiling zones tile: a column side and a stack row.
enum ZoneNavigationCell: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var side: ZoneSide {
        self == .topLeft || self == .bottomLeft ? .left : .right
    }

    var isBottom: Bool {
        self == .bottomLeft || self == .bottomRight
    }
}

/// What one press of a selection key asks for.
enum ZoneNavigationKey: Equatable {
    /// An arrow: move the circle to the next zone in that direction.
    case move(ZoneNavigationDirection)
    /// A/S/D/F: jump to the zone at that cell of the current screen, adding it when the cell has
    /// no zone of its own.
    case zone(ZoneNavigationCell)
    /// G: jump to the current screen's floating zone.
    case floatingZone
    /// J/K/L: jump to the display at this position in geometric order (0 = leftmost); the circle
    /// lands on that display's last-used window.
    case display(ordinal: Int)

    /// Whether the key jumps straight to its selection rather than stepping from the current
    /// one. Jumps are idempotent, so the gesture ignores their auto-repeats.
    var isJump: Bool {
        if case .move = self { return false }
        return true
    }
}
