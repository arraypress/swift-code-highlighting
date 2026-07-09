//
//  CodeHighlighter.swift
//  SwiftCodeHighlighting
//
//  The common interface for a syntax highlighter that colors a text storage.
//
//  Created by David Sherlock on 7/9/26.
//

import AppKit

/// A syntax highlighter that applies color attributes to a text storage.
///
/// Adopt this to provide alternative highlighting backends (e.g. a tree-sitter
/// engine) behind a single type the editor can hold.
public protocol CodeHighlighter: AnyObject {

    /// Applies highlighting to `storage`, at least covering `editedRange`
    /// (implementations typically expand to whole lines).
    func highlight(_ storage: NSTextStorage, in editedRange: NSRange)
}
