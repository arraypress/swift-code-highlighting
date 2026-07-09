//
//  TokenKind.swift
//  SwiftCodeHighlighting
//
//  The semantic role of a highlighted token.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// The semantic role of a highlighted token. A ``TokenColorProviding`` maps each
/// role to a concrete color, so the highlighter itself stays theme-agnostic.
public enum TokenKind: Sendable {
    case comment
    case string
    case keyword
    case type
    case number
    case function
    case attribute
    case variable
    case property
}
