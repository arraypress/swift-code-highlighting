//
//  TokenColorProviding.swift
//  SwiftCodeHighlighting
//
//  The color seam: supplies a concrete color for each token role and the default
//  foreground. Implement it against your theme; colors are read live at highlight
//  time, so a theme change simply needs a re-highlight.
//
//  Created by David Sherlock on 7/9/26.
//

import AppKit

/// Supplies the colors a highlighter paints with, decoupling it from any concrete
/// theme system.
public protocol TokenColorProviding {

    /// The color for a given token role.
    func color(for kind: TokenKind) -> NSColor

    /// The default text color for un-highlighted characters.
    var foreground: NSColor { get }
}
