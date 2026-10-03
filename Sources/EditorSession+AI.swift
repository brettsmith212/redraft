import AppKit

extension EditorSession {
    // MARK: AI alternatives

    func aiAlternatives(for range: NSRange?) {
        openAlternatives(for: range)
        if let id = activeGroupID { aiAlternatives(groupID: id) }
    }

    func aiAlternatives(groupID id: String) {
        guard let g = doc.groups[id], let r = range(of: .variantGroup, id: id), aiLoadingGroup == nil else { return }
        activate(id)
        let selection = string.substring(with: r)
        let context = string.substring(with: string.paragraphRange(for: r))
        let existing = g.options.map(\.text)
        aiLoadingGroup = id
        Task {
            defer { aiLoadingGroup = nil }
            do {
                // Each suggestion joins the panel the moment it arrives.
                _ = try await AIClient.alternatives(for: selection, context: context, existing: existing) { [weak self] idea in
                    self?.addOption(groupID: id, text: idea, source: .ai)
                }
                undoManager?.setActionName("AI Alternatives")
            } catch {
                report(error)
            }
        }
    }

    /// Shows an AI failure; when nothing is connected yet, offers setup instead.
    func report(_ error: Error) {
        if case AIError.notSetUp = error {
            showAISetup = true
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Lab

    func runLabTool(_ tool: LabTool) {
        let text = cleanText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, busy == nil,
              !tool.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearLab()
        busy = "\(tool.name)…"
        Task {
            defer { busy = nil }
            do {
                // Mark each result as soon as it streams in.
                var cursor = 0
                let total = Self.words(in: text)
                _ = try await AIClient.lab(tool, text: text) { [weak self] item in
                    guard let self, let r = self.locate(item.quote, cursor: &cursor) else { return }
                    let id = UUID().uuidString
                    switch tool.kind {
                    case .flag:
                        self.storage.addAttribute(.labMark, value: id, range: r)
                        self.findings.append(LabFinding(id: id, quote: item.quote, note: item.note))
                    case .cut:
                        self.storage.addAttribute(.proposedCut, value: id, range: r)
                        self.cuts.append(CutProposal(id: id, quote: item.quote, reason: item.note))
                        self.updateTrimNote(total: total)
                    }
                }
                switch tool.kind {
                case .flag: labNote = findings.isEmpty ? "Nothing flagged. Nice." : nil
                case .cut: updateTrimNote(total: total)
                }
            } catch {
                report(error)
            }
        }
    }

    private func updateTrimNote(total: Int) {
        guard !cuts.isEmpty else { labNote = "Nothing worth cutting."; return }
        let removed = cuts.reduce(0) { $0 + Self.words(in: $1.quote) }
        let percent = total > 0 ? Int((Double(removed) / Double(total) * 100).rounded()) : 0
        labNote = "\(cuts.count) cuts · about \(percent)% shorter"
    }

    static func words(in text: String) -> Int {
        var count = 0
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (text as NSString).length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// Finds a quote the model returned, preferring the next match after the
    /// previous one and skipping ghosted text.
    func locate(_ quote: String, cursor: inout Int) -> NSRange? {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let haystacks: [NSString] = [string, Self.straightenQuotes(storage.string) as NSString]
        let needles = [q, Self.straightenQuotes(q)]
        for (haystack, needle) in zip(haystacks, needles) {
            var start = cursor
            for _ in 0..<2 {
                var searchFrom = start
                while searchFrom < haystack.length {
                    let r = haystack.range(of: needle, range: NSRange(location: searchFrom, length: haystack.length - searchFrom))
                    guard r.location != NSNotFound else { break }
                    if storage.attribute(.ghost, at: r.location, effectiveRange: nil) == nil,
                       storage.attribute(.proposedCut, at: r.location, effectiveRange: nil) == nil,
                       storage.attribute(.labMark, at: r.location, effectiveRange: nil) == nil {
                        cursor = NSMaxRange(r)
                        return r
                    }
                    searchFrom = NSMaxRange(r)
                }
                start = 0
            }
        }
        return nil
    }

    private static func straightenQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    func reveal(_ key: NSAttributedString.Key, id: String) {
        guard let tv = textView, let r = range(of: key, id: id) else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
    }

    func clearLab() {
        if storage.length > 0 {
            storage.beginEditing()
            storage.removeAttribute(.labMark, range: fullRange)
            storage.removeAttribute(.proposedCut, range: fullRange)
            storage.endEditing()
        }
        findings = []
        cuts = []
        labNote = nil
    }

    func dismissFinding(_ id: String) {
        if let r = range(of: .labMark, id: id) { storage.removeAttribute(.labMark, range: r) }
        findings.removeAll { $0.id == id }
    }

    // MARK: Cuts

    func acceptCut(_ id: String) {
        guard let tv = textView, let marked = range(of: .proposedCut, id: id) else {
            cuts.removeAll { $0.id == id }
            return
        }
        storage.removeAttribute(.proposedCut, range: marked)
        let r = tidyDeletion(marked)
        tv.breakUndoCoalescing()
        if tv.shouldChangeText(in: r, replacementString: "") {
            storage.replaceCharacters(in: r, with: "")
            tv.didChangeText()
        }
        undoManager?.setActionName("Cut")
        cuts.removeAll { $0.id == id }
        if cuts.isEmpty { labNote = "All cuts made." }
    }

    func keepCut(_ id: String) {
        if let r = range(of: .proposedCut, id: id) { storage.removeAttribute(.proposedCut, range: r) }
        cuts.removeAll { $0.id == id }
        if cuts.isEmpty { labNote = nil }
    }

    func acceptAllCuts() {
        let ordered = cuts.compactMap { c in range(of: .proposedCut, id: c.id).map { (c.id, $0) } }
            .sorted { $0.1.location > $1.1.location }
        undoManager?.beginUndoGrouping()
        for (id, _) in ordered { acceptCut(id) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Cut All")
        cuts = []
        labNote = "All cuts made."
    }

    func ghostAllCuts() {
        guard let tv = textView else { return }
        undoManager?.beginUndoGrouping()
        for cut in cuts {
            guard let r = range(of: .proposedCut, id: cut.id) else { continue }
            storage.removeAttribute(.proposedCut, range: r)
            if tv.shouldChangeText(in: r, replacementString: nil) {
                storage.addAttribute(.ghost, value: true, range: r)
                tv.didChangeText()
            }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Ghost Cuts")
        cuts = []
        labNote = "Cuts ghosted. Revive anything you miss."
    }

    /// Widens a deletion so it doesn't leave a double space or a stray leading space behind.
    private func tidyDeletion(_ r: NSRange) -> NSRange {
        let ns = string
        var r = r
        let before: unichar? = r.location > 0 ? ns.character(at: r.location - 1) : nil
        let after: unichar? = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : nil
        func isSpace(_ c: unichar?) -> Bool { c == 32 || c == 9 }
        func isBreak(_ c: unichar?) -> Bool { c == nil || c == 10 || c == 13 }
        func isClosingPunctuation(_ c: unichar?) -> Bool {
            guard let c, let s = Unicode.Scalar(c) else { return false }
            return ".,;:!?)]”’\"'".unicodeScalars.contains(s)
        }
        if isSpace(before) && (isSpace(after) || isBreak(after) || isClosingPunctuation(after)) {
            r.location -= 1
            r.length += 1
        } else if (before == nil || isBreak(before)) && isSpace(after) {
            r.length += 1
        }
        return r
    }
}
