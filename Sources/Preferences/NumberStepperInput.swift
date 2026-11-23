/// A whole-number field with a stepper beside it for Preferences settings, both limited to a range.
import AppKit

/// Owners keep a reference to it, since the controls hold their target and delegate weakly.
final class NumberStepperInput: NSObject, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let stepper = NSStepper()
    /// Receives each entered value: a typed one when editing ends (Return, Tab, or losing focus), and each stepper click.
    private let onCommit: (Int) -> Void

    init(range: ClosedRange<Int>, onCommit: @escaping (Int) -> Void) {
        self.onCommit = onCommit
        super.init()

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.allowsFloats = false

        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.formatter = formatter
        // Ending editing commits; Return also sends the field's action, so the field has none.
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true

        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)
    }

    /// Shows `value` in both controls.
    func show(_ value: Int) {
        field.integerValue = value
        stepper.integerValue = value
    }

    @objc private func stepperChanged() {
        onCommit(stepper.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onCommit(field.integerValue)
    }
}
