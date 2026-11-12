//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Color palette for the Markdown editor engine.
//
//  All user-visible colors used by the engine are routed through this
//  struct. Defaults map to system colors so the editor adapts to light/
//  dark mode automatically. Embedders that want a custom palette (for
//  example, a sepia or high-contrast preset) can replace any subset of
//  the colors without touching engine source files.
//

import AppKit
import Foundation

// MARK: - Theme

/// Color palette consumed by the Markdown editor engine.
///
/// Every color the engine puts on screen is read from this struct, so a
/// single override is enough to retheme the entire editor. The defaults
/// reproduce a system-native macOS look using `NSColor` dynamic system
/// colors, so light/dark-mode switching keeps working without extra code.
public struct MarkdownEditorTheme: Sendable {

    // MARK: Text colors

    /// Foreground color for plain body text and the typing caret.
    public var bodyText: NSColor
    /// Foreground color for de-emphasized text and most syntax markers.
    /// Defaults to `secondaryLabelColor` so it tracks the system style.
    public var mutedText: NSColor
    /// Foreground color for content the engine wants to deemphasize further
    /// than `mutedText` — for example, broken wiki-links.
    public var disabledText: NSColor
    /// Foreground color for heading marker glyphs (`#`, `##`, …).
    public var headingMarker: NSColor
    /// Foreground color for heading CONTENT (the text after the markers).
    ///
    /// Defaults to `labelColor`, i.e. the same ink as ``bodyText`` — which is
    /// what GitHub's markdown CSS does: heading levels are distinguished by
    /// size and weight, not by hue. Embedders that want tinted headings can
    /// override it without touching the marker color.
    public var headingText: NSColor

    // MARK: Blockquotes

    /// Foreground color for blockquote content. The `>` markers keep using
    /// ``mutedText`` because they are syntax, not content.
    ///
    /// Defaults to `secondaryLabelColor`, the historical quote ink, so the
    /// stock look is unchanged.
    public var blockquoteText: NSColor
    /// Fill color of the blockquote's left vertical bar.
    ///
    /// `nil` (the default) keeps the historical look — ``mutedText`` at 50%,
    /// resolved at draw time so a dynamic color still follows the appearance.
    /// A GitHub-style palette passes its border hex here.
    public var blockquoteBar: NSColor?

    // MARK: Links

    /// Foreground color for hyperlinks that resolve to an URL.
    public var link: NSColor
    /// Foreground color for incomplete `[text]` patterns (no URL yet).
    public var incompleteLink: NSColor

    // MARK: Find / search highlights

    /// Background color used to highlight all matches when the user is
    /// running an in-document search.
    ///
    /// The default is `.systemYellow` so embedders that don't customize
    /// this still get a sensible result. Apps with their own brand color
    /// (for example, the Nodes app uses its custom yellow) should override
    /// this to match their palette.
    public var findMatchHighlight: NSColor
    /// Background color used to highlight the currently-focused match
    /// during in-document search. Typically a stronger version of
    /// ``findMatchHighlight``.
    public var findCurrentMatchHighlight: NSColor

    // MARK: LaTeX rendering

    /// Foreground color used when rendering LaTeX formulas in light mode.
    public var latexLightModeText: NSColor
    /// Foreground color used when rendering LaTeX formulas in dark mode.
    public var latexDarkModeText: NSColor

    // MARK: Strikethrough / decoration

    /// Stroke color used for strikethrough decorations
    /// (e.g. completed task list items, horizontal rules).
    public var strikethroughColor: NSColor
    /// Stroke color used for the horizontal rule drawn by a thematic break
    /// (`---`, `***`, `___`).
    ///
    /// `nil` (the default) keeps the historical look — ``strikethroughColor``
    /// at 40%, resolved at draw time so a dynamic color follows the
    /// appearance. GitHub's rule uses its border hex; pass that here.
    public var thematicBreak: NSColor?

    // MARK: Highlight

    /// Background color used for `==highlight==` inline markup.
    public var highlightColor: NSColor

    // MARK: Task checkboxes

    /// Tint of a CHECKED task-list checkbox (`- [x]`).
    ///
    /// `nil` (the default) uses ``bodyText``, the historical look. GitHub
    /// paints checked boxes with its accent color.
    public var taskCheckboxChecked: NSColor?

    // MARK: Tables

    /// Stroke color for the outer border and the internal grid lines of a
    /// rendered table.
    ///
    /// `nil` (the default) reproduces the historical look — ``mutedText`` at
    /// 50% — so existing embedders see no change. A GitHub-style palette sets
    /// its explicit border hex here.
    public var tableBorder: NSColor?
    /// Fill color of the table's header row.
    ///
    /// `nil` (the default) reproduces the historical look — ``mutedText`` at
    /// 8%. GitHub's markdown CSS paints the header with the canvas-inset
    /// color, which an embedder can pass explicitly.
    public var tableHeaderBackground: NSColor?
    /// Optional fill for even body rows (`nth-child(2n)` striping).
    ///
    /// `nil` (the default) draws no stripes, which is the historical look.
    /// GitHub's markdown tables stripe even rows with the canvas-inset color.
    public var tableRowStripe: NSColor?

    // MARK: Init

    public init(
        bodyText: NSColor = .labelColor,
        mutedText: NSColor = .secondaryLabelColor,
        disabledText: NSColor = .tertiaryLabelColor,
        headingMarker: NSColor = .gray,
        headingText: NSColor = .labelColor,
        blockquoteText: NSColor = .secondaryLabelColor,
        link: NSColor = .linkColor,
        incompleteLink: NSColor = .systemBlue,
        findMatchHighlight: NSColor = .systemYellow,
        findCurrentMatchHighlight: NSColor = .systemYellow,
        latexLightModeText: NSColor = .black,
        latexDarkModeText: NSColor = .white,
        strikethroughColor: NSColor = .labelColor,
        highlightColor: NSColor = .systemOrange.withAlphaComponent(0.4),
        tableBorder: NSColor? = nil,
        tableHeaderBackground: NSColor? = nil,
        tableRowStripe: NSColor? = nil,
        blockquoteBar: NSColor? = nil,
        thematicBreak: NSColor? = nil,
        taskCheckboxChecked: NSColor? = nil
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.headingMarker = headingMarker
        self.headingText = headingText
        self.blockquoteText = blockquoteText
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.latexLightModeText = latexLightModeText
        self.latexDarkModeText = latexDarkModeText
        self.strikethroughColor = strikethroughColor
        self.highlightColor = highlightColor
        self.tableBorder = tableBorder
        self.tableHeaderBackground = tableHeaderBackground
        self.tableRowStripe = tableRowStripe
        self.blockquoteBar = blockquoteBar
        self.thematicBreak = thematicBreak
        self.taskCheckboxChecked = taskCheckboxChecked
    }

    /// System-native palette built from `NSColor` dynamic system colors.
    ///
    /// Use this if you want the engine to look like a stock macOS
    /// `NSTextView`. It's also the default when no theme is supplied.
    public static let `default` = MarkdownEditorTheme()
}
