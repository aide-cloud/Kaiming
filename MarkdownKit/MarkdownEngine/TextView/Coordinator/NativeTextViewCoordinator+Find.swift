//
//  NativeTextViewCoordinator+Find.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Find-in-document highlighting. The host app posts the bus notifications
//  registered in `MarkdownEditorBus.findScrollToRange` /
//  `findClearHighlights` to drive the highlight overlay; this extension
//  renders the highlights into the underlying NSTextStorage and scrolls the
//  current match into view.
//
//  Kaiming patch: literal matches stay case-/diacritic-insensitive by default,
//  but every find/replace notification can opt into `useRegex` and
//  `caseSensitive`. Regex replacements use NSRegularExpression templates
//  (`$1`, `$2`, … numeric capture groups). Invalid patterns are reported through
//  `findResults` (`userInfo["error"]`) instead of silently matching nothing.
//

import AppKit

extension NSAttributedString.Key {
    /// Marks a background this file painted. `.backgroundColor` has other owners
    /// (extension spans, code fences, table cells), so find has to recognize its
    /// own highlights before removing any.
    static let findHighlight = NSAttributedString.Key("FindHighlight")
}

extension NativeTextViewCoordinator {
    /// A compiled find pattern. `.invalid` carries the message the host should
    /// display; it is never treated as "zero matches" silently.
    private enum FindPattern {
        case literal(String)
        case regularExpression(NSRegularExpression)
        case invalid(String)

        init(query: String, useRegex: Bool, caseSensitive: Bool) {
            guard useRegex else {
                self = .literal(query)
                return
            }
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            do {
                self = .regularExpression(try NSRegularExpression(pattern: query, options: options))
            } catch {
                self = .invalid("正则表达式无效：\(error.localizedDescription)")
            }
        }

        /// Match ranges in UTF-16 coordinates. Zero-length regex matches are
        /// dropped: they cannot be highlighted or replaced without looping.
        func ranges(in haystack: NSString, caseSensitive: Bool) -> [NSRange] {
            switch self {
            case .literal(let query):
                guard !query.isEmpty else { return [] }
                var options: NSString.CompareOptions = []
                if !caseSensitive {
                    options = [.caseInsensitive, .diacriticInsensitive]
                }
                var ranges: [NSRange] = []
                var searchStart = 0
                while searchStart < haystack.length {
                    let scope = NSRange(location: searchStart, length: haystack.length - searchStart)
                    let found = haystack.range(of: query, options: options, range: scope)
                    if found.location == NSNotFound { break }
                    if found.length > 0 { ranges.append(found) }
                    searchStart = found.location + max(found.length, 1)
                }
                return ranges

            case .regularExpression(let regex):
                let fullRange = NSRange(location: 0, length: haystack.length)
                return regex.matches(in: haystack as String, options: [], range: fullRange)
                    .map(\.range)
                    .filter { $0.length > 0 }

            case .invalid:
                return []
            }
        }

        /// Replacement text for each match. Regex templates expand capture
        /// groups against the matched text; literal mode repeats the template.
        func replacementTexts(for ranges: [NSRange], template: String, in haystack: NSString) -> [String] {
            switch self {
            case .literal:
                return Array(repeating: template, count: ranges.count)

            case .regularExpression(let regex):
                let fullRange = NSRange(location: 0, length: haystack.length)
                let results = regex.matches(in: haystack as String, options: [], range: fullRange)
                    .filter { $0.range.length > 0 }
                guard results.count == ranges.count else { return [] }
                let text = haystack as String
                return results.map {
                    regex.replacementString(for: $0, in: text, offset: 0, template: template)
                }

            case .invalid:
                return []
            }
        }
    }

    /// Legacy path: the host computes match ranges and posts them. Kept for compatibility, but
    /// it trusts SOURCE-coordinate ranges, which misalign wherever the displayed text is shorter
    /// than the source (node links etc.). Prefer `handleFindQuery`.
    @objc func handleFindScrollToRange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let currentIndex = info["currentIndex"] as? Int,
              let allRanges = info["allRanges"] as? [NSRange] else { return }
        renderFindMatches(allRanges, currentIndex: currentIndex)
    }

    /// Find against the engine's OWN displayed text (`tv.string`). Matches are computed in
    /// DISPLAY coordinates, so highlights land correctly even where the displayed text differs
    /// from the source (node links rendered shorter than `[[Name|UUID]]`, LaTeX, images). Posts
    /// the match count back via `bus.findResults` so the host can show "x of y".
    @objc func handleFindQuery(_ notification: Notification) {
        guard let tv = textView,
              let info = notification.userInfo,
              let query = info["query"] as? String else { return }
        // Every live coordinator hears this (`object: nil`), and an editor the host
        // has routed away from can outlive its view for a while — it is not the
        // document being searched, and its answer would overwrite the real one's.
        // Measured: 24 coordinators replying to one ⌘F, 22 of them windowless with
        // an empty buffer, each reporting 0 matches and resetting the host's index.
        guard tv.window != nil else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0
        let useRegex = info["useRegex"] as? Bool ?? false
        let caseSensitive = info["caseSensitive"] as? Bool ?? false

        guard !query.isEmpty else {
            clearFindHighlights(in: tv)
            postFindResults(count: 0, currentIndex: 0)
            return
        }

        let pattern = FindPattern(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        if case .invalid(let message) = pattern {
            clearFindHighlights(in: tv)
            postFindResults(count: 0, currentIndex: 0, error: message)
            return
        }

        let allRanges = pattern.ranges(in: tv.string as NSString, caseSensitive: caseSensitive)
        let currentIndex = allRanges.isEmpty ? 0 : min(max(requestedIndex, 0), allRanges.count - 1)
        renderFindMatches(allRanges, currentIndex: currentIndex)
        postFindResults(count: allRanges.count, currentIndex: currentIndex)
    }

    /// All ranges of `query` in `haystack` (display coordinates), case- and
    /// diacritic-insensitive. Shared by find and replace.
    ///
    /// Kaiming patch: `useRegex` / `caseSensitive` are optional so existing
    /// callers keep the historical literal behaviour.
    func findMatches(
        of query: String,
        in haystack: NSString,
        useRegex: Bool = false,
        caseSensitive: Bool = false
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let pattern = FindPattern(query: query, useRegex: useRegex, caseSensitive: caseSensitive)
        return pattern.ranges(in: haystack, caseSensitive: caseSensitive)
    }

    private func postFindResults(count: Int, currentIndex: Int = 0, error: String? = nil) {
        guard let resultsName = configuration.services.bus.findResults else { return }
        var userInfo: [AnyHashable: Any] = [
            "count": count,
            "currentIndex": currentIndex
        ]
        if let error { userInfo["error"] = error }
        NotificationCenter.default.post(name: resultsName, object: nil, userInfo: userInfo)
    }

    /// Replace the current find match with the replacement string (one undo
    /// step), then re-highlight and report the remaining match count.
    @objc func handleReplaceCurrent(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0
        let useRegex = info["useRegex"] as? Bool ?? false
        let caseSensitive = info["caseSensitive"] as? Bool ?? false
        let pattern = FindPattern(query: query, useRegex: useRegex, caseSensitive: caseSensitive)

        if case .invalid(let message) = pattern {
            postFindResults(count: 0, currentIndex: 0, error: message)
            return
        }

        let haystack = tv.string as NSString
        let matches = pattern.ranges(in: haystack, caseSensitive: caseSensitive)
        guard !matches.isEmpty else {
            postFindResults(count: 0, currentIndex: 0)
            return
        }
        let idx = min(max(requestedIndex, 0), matches.count - 1)
        let target = matches[idx]
        guard NSMaxRange(target) <= haystack.length else { return }
        guard let replacementText = pattern
            .replacementTexts(for: [target], template: replacement, in: haystack)
            .first else { return }

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(in: target, replacementString: replacementText) else { return }
        tv.textStorage?.replaceCharacters(in: target, with: replacementText)
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace")
        tv.breakUndoCoalescing()

        // Re-find on the edited text; keep the index so focus lands on the next
        // occurrence (or clamps to the last remaining one).
        let updated = pattern.ranges(in: tv.string as NSString, caseSensitive: caseSensitive)
        let nextIndex = updated.isEmpty ? 0 : min(idx, updated.count - 1)
        renderFindMatches(updated, currentIndex: nextIndex)
        postFindResults(count: updated.count, currentIndex: nextIndex)
    }

    /// Replace every find match in a single undo step, then re-highlight.
    @objc func handleReplaceAll(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }
        let useRegex = info["useRegex"] as? Bool ?? false
        let caseSensitive = info["caseSensitive"] as? Bool ?? false
        let pattern = FindPattern(query: query, useRegex: useRegex, caseSensitive: caseSensitive)

        if case .invalid(let message) = pattern {
            postFindResults(count: 0, currentIndex: 0, error: message)
            return
        }

        let haystack = tv.string as NSString
        let matches = pattern.ranges(in: haystack, caseSensitive: caseSensitive)
        guard !matches.isEmpty else {
            postFindResults(count: 0, currentIndex: 0)
            return
        }
        let replacements = pattern.replacementTexts(for: matches, template: replacement, in: haystack)
        guard replacements.count == matches.count else { return }

        // Group as one undo; `shouldChangeText` expects ascending, non-overlapping
        // ranges, while the storage edits run back-to-front so earlier ranges stay valid.
        let orderedRanges = matches.map { NSValue(range: $0) }

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(inRanges: orderedRanges, replacementStrings: replacements) else { return }
        tv.textStorage?.beginEditing()
        for (range, text) in zip(matches, replacements).reversed() {
            tv.textStorage?.replaceCharacters(in: range, with: text)
        }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace All")
        tv.breakUndoCoalescing()

        // Usually zero remain; non-zero only if the replacement contains the query.
        let remaining = pattern.ranges(in: tv.string as NSString, caseSensitive: caseSensitive)
        renderFindMatches(remaining, currentIndex: 0)
        postFindResults(count: remaining.count, currentIndex: 0)
    }

    /// Drop find's own backgrounds and restyle the paragraphs they sat in.
    ///
    /// Removing `.backgroundColor` takes the styling background with it - one
    /// attribute, several owners - and nothing repaints it on its own, so an
    /// `==` block stayed blank until the next restyle happened to run (a click).
    /// Scoped to the marked ranges: paragraphs find never touched keep theirs.
    private func clearFindHighlights(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        var highlighted: [NSRange] = []
        storage.enumerateAttribute(
            .findHighlight,
            in: NSRange(location: 0, length: text.length),
            options: []
        ) { value, range, _ in
            if value != nil { highlighted.append(range) }
        }
        guard !highlighted.isEmpty else { return }

        for range in highlighted {
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(.findHighlight, range: range)
        }
        // Raw source mode has no styling to restore; restyleParagraphs no-ops there.
        restyleParagraphs(highlighted.map { text.paragraphRange(for: $0) }, in: textView)
    }

    /// Highlight all matches (current one stronger) and scroll the current match into view.
    private func renderFindMatches(_ allRanges: [NSRange], currentIndex: Int) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)

        clearFindHighlights(in: tv)

        // Highlight all matches; the focused match gets a stronger color.
        let theme = configuration.theme
        let matchAlpha = configuration.markers.findMatchHighlightAlpha
        let highlightColor = theme.findMatchHighlight.withAlphaComponent(matchAlpha)
        let currentHighlightColor = theme.findCurrentMatchHighlight

        for (i, matchRange) in allRanges.enumerated() {
            guard matchRange.location + matchRange.length <= fullRange.length else { continue }
            let color = (i == currentIndex) ? currentHighlightColor : highlightColor
            storage?.addAttribute(.backgroundColor, value: color, range: matchRange)
            storage?.addAttribute(.findHighlight, value: true, range: matchRange)
        }

        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Scroll the current match into view.
        guard allRanges.indices.contains(currentIndex) else { return }
        let range = allRanges[currentIndex]
        guard range.location + range.length <= fullRange.length else { return }
        // Scroll via TextKit 2 fragment layout, which works whether or not the
        // reading column is active. `scrollRangeToVisible` is unreliable for
        // off-screen content in a TextKit 2 text view (it routes through the
        // absent TextKit 1 layout manager), so it's only the last-resort fallback.
        guard let tlm = tv.textLayoutManager,
              let scrollView = tv.enclosingScrollView,
              let matchStart = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: range.location) else {
            tv.scrollRangeToVisible(range)
            return
        }
        tlm.enumerateTextLayoutFragments(from: matchStart, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            // Fragment frames are text-view-local; the scroll offset is in the clip view's space.
            let frame = tv.rectInClipView(fragment.layoutFragmentFrame)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            // Only scroll when the match is off-screen; reveal it a little below the top.
            if frame.minY < visibleTop || frame.maxY > visibleBottom {
                let targetY = frame.minY - insetsTop - cv.bounds.height * 0.2
                (scrollView as? ClampedScrollView)?.cancelPendingScrollRestore()
                cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(cv)
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
            return false
        }
    }

    @objc func handleFindClearHighlights(_ notification: Notification) {
        guard let tv = textView else { return }
        let scrollView = tv.enclosingScrollView
        let preY = scrollView?.contentView.bounds.origin.y ?? 0
        let insetsTop = scrollView?.contentInsets.top ?? 0
        let visualTopDocY = preY + insetsTop
        var anchorOffsetFromTop: CGFloat = 0
        var anchorTextRange: NSTextRange? = nil
        // Fragment frames are text-view-local; visualTopDocY is in the clip view's space.
        if let tlm = tv.textLayoutManager {
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = tv.rectInClipView(fragment.layoutFragmentFrame)
                if frame.maxY < visualTopDocY { return true }
                anchorTextRange = fragment.rangeInElement
                anchorOffsetFromTop = visualTopDocY - frame.minY
                return false
            }
        }

        clearFindHighlights(in: tv)
        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        if let tlm = tv.textLayoutManager, let anchor = anchorTextRange {
            tlm.enumerateTextLayoutFragments(from: anchor.location, options: [.ensuresLayout]) { fragment in
                let newDocY = tv.rectInClipView(fragment.layoutFragmentFrame).minY + anchorOffsetFromTop
                let targetScrollY = newDocY - insetsTop
                if let cv = scrollView?.contentView, abs(cv.bounds.origin.y - targetScrollY) > 0.5 {
                    cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetScrollY))
                    scrollView?.reflectScrolledClipView(cv)
                }
                return false
            }
        }
    }
}
