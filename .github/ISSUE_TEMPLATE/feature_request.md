---
name: Feature request
about: Suggest an idea for NotifMirror
title: ''
labels: enhancement
assignees: ''
---

**What problem does this solve?**
Describe the user-facing need in a sentence or two.

**Proposed behavior**
How should it work? Sketch the UX if that helps.

**Wire impact (please think about this)**
NotifMirror mirrors the wire protocol between Kotlin and Swift. If this
feature needs a new message type or a field change, note it here — unknown
`t` values are ignored by older peers, so new messages are safe, but field
changes to existing messages are not.

**Alternative approaches**
Anything you've considered instead.
