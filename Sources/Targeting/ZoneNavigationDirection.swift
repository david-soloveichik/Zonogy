/// The four arrow directions of Control-Command zone navigation.
enum ZoneNavigationDirection {
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
