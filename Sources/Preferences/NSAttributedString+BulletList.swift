/// Formats Preferences text as a bulleted list, one item per line, with wrapped lines indented under the text.
import AppKit

extension NSAttributedString {
    static func bulletList(_ items: [String], font: NSFont, color: NSColor) -> NSAttributedString {
        let indent: CGFloat = 12
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 4
        return NSAttributedString(
            string: items.map { "•\t\($0)" }.joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }
}
