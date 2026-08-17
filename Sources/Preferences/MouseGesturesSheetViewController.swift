/// The Mouse Gestures editor: the modifiers held while clicking or dragging, and a walkthrough of
/// what each click or drag then does. Nothing else to set, so the walkthrough is fixed.
import AppKit

final class MouseGesturesSheetViewController: ModifierCombinationSheetViewController {
    /// Called with the chosen combination when the user confirms (guaranteed valid).
    var onSave: ((ModifierCombination) -> Void)?

    init() {
        super.init(
            title: "Mouse Gestures",
            subtitle: "Choose the modifier keys to hold while clicking or dragging.",
            modifiersHint: "Select at least two.",
            walkthroughHeader: "What the gestures do",
            initialModifiers: ModifierCombinationPreferences.mouseGestures.modifiers
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeWalkthrough() -> Walkthrough {
        Walkthrough(items: [
            .heading("While holding the modifier keys:"),
            // One column: these triggers are phrases, not caps, so a second column would leave
            // too little room for the descriptions.
            .steps([
                Walkthrough.Step(
                    trigger: .gesture("click"),
                    detail: "Make a tiling zone the destination"),
                Walkthrough.Step(
                    trigger: .gesture("double-click"),
                    detail: "Make it the destination and open the Launcher"),
                Walkthrough.Step(
                    trigger: .gesture("drag a tiled window"),
                    detail: "Move it into the floating zone"),
                Walkthrough.Step(
                    trigger: .gesture("drag a floating window"),
                    detail: "Drop it into an occupied zone, replacing that window"),
                Walkthrough.Step(
                    trigger: .gesture("drag from another app"),
                    detail: "Route the drop into a zone"),
            ], columns: 1),
        ])
    }

    override func commit(_ modifiers: ModifierCombination) {
        onSave?(modifiers)
    }
}
