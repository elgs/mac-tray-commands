import SwiftUI
import AppKit

// MARK: - Composite view: line numbers + editor

struct ShellEditorWithLineNumbers: View {
    let text: String
    let onChange: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var lineHeights: [CGFloat] = [17]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Line number gutter
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(lineHeights.enumerated()), id: \.offset) { index, height in
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(lineNumberColor)
                        .frame(height: height, alignment: .top)
                }
                Spacer()
            }
            .padding(.top, 8)
            .padding(.trailing, 6)
            .padding(.leading, 6)
            .frame(minWidth: 36)
            .background(gutterColor)

            // Syntax-highlighted editor
            HighlightedShellEditor(text: text, onChange: onChange) { heights in
                lineHeights = heights
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private var isDark: Bool { colorScheme == .dark }

    private var gutterColor: Color {
        isDark
            ? Color(nsColor: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1.0))
    }

    private var lineNumberColor: Color {
        isDark
            ? Color(nsColor: NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1.0))
            : Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0))
    }
}

// MARK: - NSTextView wrapper with syntax highlighting

struct HighlightedShellEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onLineHeightsChange: ([CGFloat]) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onLineHeightsChange: onLineHeightsChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.postsFrameChangedNotifications = true

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set text ONCE, never overwrite from updateNSView
        textView.string = text
        let isDark = colorScheme == .dark
        applyAppearance(to: textView, isDark: isDark)
        Coordinator.applyHighlighting(to: textView, isDark: isDark)

        // Delegate after text is set
        textView.delegate = context.coordinator

        // Observe frame changes (window resize → text reflows → line heights change)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )

        // Initial line heights after layout
        DispatchQueue.main.async {
            context.coordinator.reportLineHeights()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let isDark = colorScheme == .dark
        applyAppearance(to: textView, isDark: isDark)
        Coordinator.applyHighlighting(to: textView, isDark: isDark)
    }

    private func applyAppearance(to textView: NSTextView, isDark: Bool) {
        textView.backgroundColor = isDark
            ? NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
            : NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
        textView.insertionPointColor = isDark ? .white : .black
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        let onChange: (String) -> Void
        let onLineHeightsChange: ([CGFloat]) -> Void

        init(onChange: @escaping (String) -> Void, onLineHeightsChange: @escaping ([CGFloat]) -> Void) {
            self.onChange = onChange
            self.onLineHeightsChange = onLineHeightsChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Coordinator.applyHighlighting(to: textView, isDark: isDark)
            onChange(textView.string)
            reportLineHeights()
        }

        @objc func frameDidChange() {
            reportLineHeights()
        }

        func reportLineHeights() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)

            let nsText = textView.string as NSString
            var heights: [CGFloat] = []

            if nsText.length == 0 {
                heights = [17]
            } else {
                var index = 0
                while index < nsText.length {
                    let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
                    let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

                    var totalHeight: CGFloat = 0
                    if glyphRange.length > 0 {
                        var glyphIndex = glyphRange.location
                        while glyphIndex < NSMaxRange(glyphRange) {
                            var effectiveRange = NSRange()
                            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
                            totalHeight += rect.height
                            glyphIndex = NSMaxRange(effectiveRange)
                        }
                    } else {
                        totalHeight = 17
                    }

                    heights.append(totalHeight)

                    let next = NSMaxRange(lineRange)
                    if next <= index { break }
                    index = next
                }

                // Trailing newline means one more empty line
                if nsText.length > 0 && nsText.character(at: nsText.length - 1) == 0x0A {
                    heights.append(17)
                }
            }

            onLineHeightsChange(heights)
        }

        // MARK: - Syntax Highlighting

        static func applyHighlighting(to textView: NSTextView, isDark: Bool) {
            let storage = textView.textStorage!
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            let fullRange = NSRange(location: 0, length: length)
            let nsText = textView.string as NSString

            let c: [NSColor] = isDark ? [
                NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0),
                NSColor(red: 0.45, green: 0.50, blue: 0.45, alpha: 1.0),
                NSColor(red: 0.64, green: 0.83, blue: 0.46, alpha: 1.0),
                NSColor(red: 0.55, green: 0.78, blue: 0.96, alpha: 1.0),
                NSColor(red: 0.94, green: 0.55, blue: 0.66, alpha: 1.0),
                NSColor(red: 0.40, green: 0.72, blue: 0.94, alpha: 1.0),
                NSColor(red: 0.85, green: 0.65, blue: 0.40, alpha: 1.0),
                NSColor(red: 0.82, green: 0.68, blue: 0.96, alpha: 1.0),
            ] : [
                NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0),
                NSColor(red: 0.40, green: 0.46, blue: 0.40, alpha: 1.0),
                NSColor(red: 0.30, green: 0.55, blue: 0.20, alpha: 1.0),
                NSColor(red: 0.15, green: 0.45, blue: 0.70, alpha: 1.0),
                NSColor(red: 0.75, green: 0.15, blue: 0.35, alpha: 1.0),
                NSColor(red: 0.10, green: 0.40, blue: 0.70, alpha: 1.0),
                NSColor(red: 0.65, green: 0.40, blue: 0.10, alpha: 1.0),
                NSColor(red: 0.55, green: 0.30, blue: 0.75, alpha: 1.0),
            ]

            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: c[0], range: fullRange)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)

            apply(#"(?m)#.*$"#, storage, nsText, c[1])
            apply(#""(?:[^"\\]|\\.)*""#, storage, nsText, c[2])
            apply(#"'[^']*'"#, storage, nsText, c[2])
            apply(#"\$\{?[A-Za-z_0-9]+\}?"#, storage, nsText, c[3])
            apply("\\b(if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|return|exit|local|export|readonly|declare|source|eval|exec|set|unset)\\b", storage, nsText, c[4])
            apply("(?m)(?:^|(?<=;)|(?<=&&)|(?<=\\|\\|)|(?<=\\|))\\s*(cd|ls|cp|mv|rm|mkdir|rmdir|touch|cat|echo|printf|grep|sed|awk|find|chmod|chown|curl|wget|tar|zip|unzip|git|docker|npm|yarn|pip|brew|sudo|ssh|scp|rsync|make|xcodebuild|code)\\b", storage, nsText, c[5], 1)
            apply(#"(?:\|\||&&|>>|2>&1|[|;<>])"#, storage, nsText, c[6])
            apply(#"\b\d+\b"#, storage, nsText, c[7])

            storage.endEditing()
        }

        private static func apply(_ pattern: String, _ storage: NSTextStorage, _ nsText: NSString, _ color: NSColor, _ group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: nsText as String, range: NSRange(location: 0, length: nsText.length)) {
                let r = match.range(at: group)
                if r.location != NSNotFound { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
    }
}
