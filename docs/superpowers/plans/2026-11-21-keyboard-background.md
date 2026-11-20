# Keyboard background adjustment

User requested a translucent keyboard with backgrounds confined to keys and authorized recommended decisions without further questions.

Design: remove the tinted transcript glass panel and controls outline; keep system glass button surfaces and adaptive label colors. Explicitly clear the extension root without modifying system-owned keyboard views. Compared with reducing panel tint, removing the panel avoids an extra material slab. Do not alter recording behavior, spacing or touch targets. Keep code comments concise.

- [x] Inspect existing rendering and Apple UIInputView background behavior.
- [x] Remove non-key chrome in KeyboardRootView and clear extension view.
- [x] Run existing unsigned UIKit and preview layout/snapshot checks; inspect light/dark results.
- [ ] Review diff and commit/push with temporary Codex identity and no signing.

Verification: unsigned UIKit tests (52), preview layout cases (10), and preview snapshot cases (10) passed. Light and dark images were inspected. Preview-only system backgrounds make transparent content visible during inspection. Independent review found no actionable issues. Real host keyboard backdrop remains device-dependent and has not been visually tested on a physical device.
