//
//  Attribution.swift
//  ClickyShared
//
//  MIT-license attribution text used by the iOS Yapr app's About screen.
//  The original Clicky open-source codebase is MIT-licensed, which requires
//  retaining the copyright notice in any substantial reuse — this string
//  centralizes that notice so all consumers display it consistently.
//

import Foundation

public enum Attribution {
    /// Short, single-line credit suitable for an About row.
    public static let shortCredit = "Engine based on Clicky by Farza — MIT licensed"

    /// Full credit block suitable for a Settings → About → Acknowledgements
    /// screen. Includes the MIT copyright notice as required by the license.
    public static let fullCredit = """
    The voice + Claude + ElevenLabs + AssemblyAI engine in this app is a port of the open-source Clicky macOS app (https://github.com/farzaa/clicky), used and adapted under the MIT License.

    MIT License
    Copyright (c) 2026 Farza

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
    """
}
