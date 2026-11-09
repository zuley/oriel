---
target: 小窗整体 UI 与交互
total_score: 22
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 4
target_identity: "file:/Users/zley/WORK/Github/oriel/OrielApp/MiniWindowChromeView.swift"
target_fingerprint: "sha256:0b622b640733f6d86bd4d9c5ef7843b2c60512b0f1e10b1b0f8a14acf386049f"
target_path: /Users/zley/WORK/Github/oriel/OrielApp/MiniWindowChromeView.swift
timestamp: 2026-11-08T07-29-50Z
slug: orielapp-miniwindowchromeview-swift
---
Method: design review only (detector not applicable, native macOS AppKit app)

## Design Health Score (22/40, Acceptable)
1 Visibility of system status 2 · 2 Match real world 2 · 3 User control 2 · 4 Consistency 2 · 5 Error prevention 2 · 6 Recognition 2 · 7 Flexibility 3 · 8 Minimalist 3 · 9 Error recovery 3 · 10 Help 1

## Design specificity
The interaction model (click-through lock, edge reveal, two-layer opacity) is specific to this product. The visual layer (grey line icons, slogan home, blue tab chips) is category-generic.

## Priority issues
- [P1] Toolbar: six unlabeled controls plus title in one 28pt row; eye / sliders / lock metaphors need tooltips; at <280pt the eye disappears and the window name truncates to "小…".
- [P1] Tab strip: numeric titles (终端 1, 网页 4), overflow collapses to one picker showing 3 of 5 tabs, system-blue selection clashes with the grey palette and the green management window, costs 28pt of a 360pt window.
- [P1] Home launcher: slogan and a non-interactive "+" illustration take the prime area; real entries are 44x56 tiles with 2.08:1 label contrast at the default content opacity.
- [P1] Contrast: secondary #9a9a9a is 2.79:1 on the window background and 2.08:1 at 0.75 content opacity; fails WCAG AA for text.
- [P2] Red dot closes the whole window with every tab and terminal in one click, 18pt from the yellow dot; only unsaved notes are protected.
- [P2] Window modes (穿透, 边缘唤醒) have no first-run explanation and no persistent status beyond icon tint.

## Architecture finding
MiniPanel.swift (1206 lines) drives pages through one Page enum with 4 repeated switches and a Tab class with 9 optional fields; adding the browser touched about 8 places.
