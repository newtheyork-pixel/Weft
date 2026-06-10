# Handoff: class-first teacher redesign (2026-06-10)

State transferred from Thomas's other Mac mid-task. Give this file to Claude Code
on this machine and ask it to continue.

## What's in the working tree (committed on this WIP branch)

- `Weft/ReviewGradingView.swift` — FIXED: Final-comment placeholder overlay used
  iOS insets (16pt top); macOS TextEditor has zero top inset, so the caret blinked
  above the placeholder line. Now 8pt. Build-verified.
- `Weft.xcodeproj/project.pbxproj` — LOCAL-ONLY tweak: MACOSX_DEPLOYMENT_TARGET
  lowered 26.3 → 26.1 (the Mac runs 26.1; 26.3 was a mix-up with the Xcode
  version). Do not ship without the repo owner's sign-off.

## The task in progress

Implement the approved spec `docs/superpowers/specs/2026-06-10-class-first-teacher-design.md`
(class-first teacher home), with this USER DIRECTION OVERRIDING the spec where
they conflict:

- Teacher home is CLASS-based, not Build/Live mode tabs.
- Teachers do NOT grade during a live session: live surface = monitoring only,
  NO "Review essays" on the live card. Grading is reached from a class's
  session history at any time — typically days after the session closed.
- Three jobs to serve: (1) build assignments, (2) monitor a live session,
  (3) grade later. Grading keys on an explicit session, never ambient liveSession.

## Workflow checkpoint

- `handoff/workflow-script.js` — the full orchestration script (Understand →
  Design → Implement → Review). Run it with the Workflow tool,
  `args: {"repo": "<absolute path to this repo>"}`.
- `handoff/journal.jsonl` — journal from run `wf_bccbeeb1-06a`. Phase
  "Understand" COMPLETED: the 4 reader agents' structured maps (teacher UI,
  state/data layer, student-home UI pattern, repo conventions) are in the
  4 `"type":"result"` entries. The Design phase had just started; nothing
  after the readers is cached.

Fastest continuation: extract the 4 reader result payloads from
`journal.jsonl` and hand them to the Design phase (edit the script to accept
maps via args), or simply re-run the whole script fresh — the Understand
phase only costs ~5 minutes.

Build verification command (works headless, no signing):
`xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug CODE_SIGNING_ALLOWED=NO build`
