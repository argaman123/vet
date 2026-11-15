# Third-party notices

Vet is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). The material
below comes from other projects and stays under its own license.

## Visual Studio Code

The diff engine is a Swift port of Visual Studio Code's diff computer, and its tests use Visual
Studio Code's diff fixtures. Section staging follows the approach of its git extension.

- `Sources/VetCore/Diff/LineDiff.swift`
- `Sources/VetCore/Diff/CharDiff.swift`
- `Sources/VetCore/Diff/DiffAlgorithms.swift`
- `Sources/VetCore/Diff/DiffHeuristics.swift`
- `Sources/VetCore/Diff/SectionStaging.swift`
- `Tests/VetCoreTests/DiffAlgorithmTests.swift`

Source: <https://github.com/microsoft/vscode>

```
MIT License

Copyright (c) 2015 - present Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## IntelliJ Platform

The fuzzy matcher and file ranking (`Sources/VetCore/Search/FuzzyMatcher.swift`,
`Sources/VetCore/Search/FileRanking.swift`) are written to behave like the IntelliJ Platform's
name matcher. They are an independent implementation, not a copy of its source.

Source: <https://github.com/JetBrains/intellij-community>, Copyright JetBrains s.r.o.

## Google Sans Code

The bundled code font, `Resources/Fonts/GoogleSansCode-*.ttf`.

Copyright 2025 The Google Sans Code Project Authors
(<https://github.com/googlefonts/googlesans-code>). Licensed under the SIL Open Font License,
Version 1.1. The full text is in [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt).

## Language servers

Vet does not include any language server. `scripts/install-language-servers.sh` downloads
them from their own publishers onto your Mac, under their own licenses.

## Names

Claude, Visual Studio Code, WebStorm and IntelliJ are trademarks of their owners. Vet is an
independent project and is not affiliated with or endorsed by any of them.
