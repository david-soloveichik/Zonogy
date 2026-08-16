/// Joining names into an English list, for user-facing sentences built from a variable number of
/// items.
import Foundation

extension Array where Element == String {
    /// The items as one phrase: "A", "A and B", "A, B, and C".
    var naturalList: String {
        count <= 2
            ? joined(separator: " and ")
            : dropLast().joined(separator: ", ") + ", and \(last ?? "")"
    }
}
