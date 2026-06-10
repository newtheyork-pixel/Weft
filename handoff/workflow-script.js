export const meta = {
  name: 'class-first-teacher',
  description: 'Design + implement class-first teacher home: build assignments, monitor live, grade days later',
  phases: [
    { title: 'Understand', detail: 'parallel readers over teacher views, state, data layer, UI patterns' },
    { title: 'Design', detail: 'three design lenses, judge panel, synthesis into one plan' },
    { title: 'Implement', detail: 'sequential build-verified steps: data, state, views' },
    { title: 'Review', detail: 'parallel reviewers, adversarial verify, fix pass' },
  ],
}

const REPO = args.repo
const CTX = `
Repo: ${REPO} (native macOS SwiftUI app "Weft" — proctored essay exams; teacher + student roles; Supabase backend).
Branch: phase2-native-wiring. Do NOT commit. Do NOT touch ${REPO}/Weft.xcodeproj/project.pbxproj.
Approved spec to honor: ${REPO}/docs/superpowers/specs/2026-06-10-class-first-teacher-design.md (READ IT).
Build command (must pass): cd ${REPO} && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug CODE_SIGNING_ALLOWED=NO build

USER'S PRODUCT DIRECTION (overrides the spec where they conflict):
- The teacher home must be CLASS-based, not mode-based (Build/Live tabs are wrong).
- Teachers do NOT grade during a live session. They monitor live (proctoring roster), then come back DAYS LATER to grade. "Review essays" must NOT be a live-mode affordance: grading is reached from a class's session history at any time, including long after the session closed. The live surface is for monitoring only.
- Three teacher jobs to serve cleanly: (1) BUILD assignments, (2) MONITOR a live session, (3) GRADE later.
`

const MAP_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    keyFacts: { type: 'array', items: { type: 'string' } },
    callSites: { type: 'array', items: { type: 'string' }, description: 'file:line — every place the relevant symbols are read/written' },
    risks: { type: 'array', items: { type: 'string' } },
  },
  required: ['summary', 'keyFacts', 'callSites', 'risks'],
}

phase('Understand')
const readers = await parallel([
  () => agent(`${CTX}
Map the teacher-facing UI. Read in full: ${REPO}/Weft/TeacherHomeView.swift, ${REPO}/Weft/TeacherRosterView.swift, ${REPO}/Weft/ReviewGradingView.swift, ${REPO}/Weft/DevGalleryView.swift.
Report: view structure; every read/write of app.teacherTab, app.liveSession, app.roster, app.openGrading/loadGrading, pickedAssignmentId/pickedClassId; how ReviewGradingView decides live vs sample data; which DevGalleryView/DevScreen entries reference teacher screens (they must keep compiling); the UI vocabulary used (GlassCard, Chip, Kicker, sectionHeader, Theme.sans/Space/Radius, .buttonStyle(.glass), rowHover(), linkPointer(), errorBanner).
callSites: exact file:line for everything that must change when TeacherTab is retired and grading takes an explicit session.`, { label: 'read:teacher-ui', schema: MAP_SCHEMA }),
  () => agent(`${CTX}
Map the state + data layer. Read in full: ${REPO}/Weft/AppState.swift, ${REPO}/Weft/SupabaseManager.swift, ${REPO}/Weft/Models.swift.
Report: the exact query/RPC style SupabaseManager uses (so a new listClassSessions(classId:) matches it — show 2-3 representative existing methods verbatim in keyFacts, e.g. listOpenSessions, listSessionStudents, listSessionSubmissions, listGrades, launchSession, endAllOpenSessions); how ExamSession decodes today and what adding optional created_at requires; AppState teacher state lifecycle: enterTeacher/loadTeacherHome/launchSession/endSession/openGrading/loadGrading/signOut resets/dropMockData, the mock-when-signed-out pattern, and the one-live-session invariant.
callSites: every AppState member the redesign touches, with file:line.`, { label: 'read:state-data', schema: MAP_SCHEMA }),
  () => agent(`${CTX}
Map the navigation/visual pattern to mirror. Read in full: ${REPO}/Weft/StudentClassHomeView.swift, ${REPO}/Weft/Components.swift, ${REPO}/Weft/Glass.swift, ${REPO}/Weft/Theme.swift.
The spec says the teacher home becomes two levels (classes list -> class detail) "mirroring the student home". Report exactly how the student home does it: the selectedClassId-driven two-level swap, back control, header treatment, card/list idioms, empty states, LIVE-ish badges, animation, error banner; and the reusable components available (signatures). keyFacts should be concrete enough that a view author can match the idiom without re-reading these files.`, { label: 'read:ui-pattern', schema: MAP_SCHEMA }),
  () => agent(`${CTX}
Map conventions + history. Read the spec file fully, plus ${REPO}/docs/superpowers/plans/2026-06-10-editor-wave-2.md and ${REPO}/docs/superpowers/specs/2026-06-09-submissions-drafts-class-home-design.md (skim for structure/conventions). Run: cd ${REPO} && git log --oneline -25, and git status --short.
Report: the repo's code-comment style (file headers, invariant comments), how prior plans sliced work into tasks, any prior decisions that constrain this change (one-live-session sweep, first-release email gating, mock-when-signed-out), and anything in git status that implementers must not clobber.`, { label: 'read:conventions', schema: MAP_SCHEMA }),
])
const maps = readers.filter(Boolean)
const mapsJSON = JSON.stringify(maps)
log(`Understanding complete: ${maps.length}/4 maps`)

phase('Design')
const LENSES = [
  { key: 'workflow', brief: 'TEACHER-WORKFLOW lens: optimize the three jobs — build, monitor live, grade days later. Where does each job live, what does the teacher see day-of vs three days after, how many clicks to grade a closed session, what does the empty/no-live state look like. Be opinionated about what is on the live card (monitoring only) and where grading entry points go.' },
  { key: 'minimal-risk', brief: 'MINIMAL-DELTA / RISK lens: the smallest correct change that delivers the spec + user direction without breaking: one-live-session invariant, signOut resets, mock/preview (signed-out) demoability, open-session restore on relaunch, first-release email gating, DevGallery compilation. Enumerate every call site that changes and what happens to it.' },
  { key: 'data-integrity', brief: 'DATA-INTEGRITY lens: grading must key on an explicit session (gradingSession), never ambient liveSession. Design listClassSessions (columns, ordering, status filter), ExamSession.created_at tolerant decode, title resolution test_id->title, what loads when a class detail opens, staleness/races (end session while grading open, relaunch mid-session), and per-class state reset rules.' },
]
const designs = (await parallel(LENSES.map(l => () =>
  agent(`${CTX}
Codebase maps from reader agents (JSON): ${mapsJSON}

You are one of three designers. ${l.brief}

Produce a CONCRETE implementation design for the class-first teacher home: exact new/changed AppState members and function signatures, exact SupabaseManager additions, the TeacherHomeView two-level structure (named sections, what renders in each state), ReviewGradingView changes, and the preview/mock story. File-by-file. Note anywhere you deliberately deviate from the spec to honor the user's direction (grading not in live). Return the design as plain text.`, { label: `design:${l.key}` })
    .then(d => ({ lens: l.key, text: d }))
))).filter(Boolean)

const judges = (await parallel([
  () => agent(`${CTX}
Three designs for the same change follow. Judge them strictly as the TEACHER who uses this every week: which serves build / monitor-live / grade-3-days-later best, with fewest surprises? Score each 1-10 with reasons; name the winner and the best ideas worth grafting from the others.
${designs.map(d => `--- DESIGN ${d.lens} ---\n${d.text}`).join('\n')}`, { label: 'judge:ux' }),
  () => agent(`${CTX}
Three designs for the same change follow. Judge them strictly as a SENIOR REVIEWER guarding correctness: invariants preserved (one live session, signOut reset, mock preview, relaunch restore, release-email gating), races, decode safety, regression surface. Score each 1-10 with reasons; name the winner and the must-keep safeguards from the others.
${designs.map(d => `--- DESIGN ${d.lens} ---\n${d.text}`).join('\n')}`, { label: 'judge:correctness' }),
])).filter(Boolean)

const plan = await agent(`${CTX}
Codebase maps (JSON): ${mapsJSON}

Synthesize ONE final implementation plan from the three designs and two judge verdicts below. Take the winner's spine and graft the judges' must-keeps. The plan must be complete enough that three implementers can execute it without re-deciding anything, split into exactly these steps:
STEP 1 — DATA: Models.swift (ExamSession.created_at as optional Date with tolerant decode; keep all existing call sites compiling) + SupabaseManager.listClassSessions(classId:) matching house query style.
STEP 2 — STATE: AppState.swift: teacherSelectedClassId, classSessions + load, gradingSession + openGrading(session:title:)/loadGrading taking the explicit session, retire TeacherTab (delete the enum + teacherTab), update enterTeacher/loadTeacherHome (prime selection to live class), launchSession (in-place live card, guard message names owning class), endSession (refresh history; no tab), signOut resets, dropMockData/preview mocks (two mock classes; one open + one closed mock session so signed-out demo works), and exact behavior for roster mock (never show fake students when signed in).
STEP 3 — VIEWS: TeacherHomeView.swift two-level rewrite (classes list w/ LIVE badge + Library section; class detail w/ Live-now monitoring card (NO grading button), launch row, Sessions history w/ per-row Review essays, Roster entry, back control) matching the student-home idiom; ReviewGradingView.swift reads gradingSession; DevGalleryView kept compiling.
For each step list: exact files, exact edits (signatures, state members, view sections), and what the step's build proves. Include a final QA checklist. Plain text.
--- DESIGNS ---
${designs.map(d => `--- DESIGN ${d.lens} ---\n${d.text}`).join('\n')}
--- JUDGE (teacher UX) ---
${judges[0] ?? 'n/a'}
--- JUDGE (correctness) ---
${judges[1] ?? 'n/a'}`, { label: 'synthesize-plan' })
log('Final plan synthesized')

phase('Implement')
const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    buildStatus: { type: 'string', enum: ['green', 'red'] },
    notes: { type: 'string' },
  },
  required: ['summary', 'filesChanged', 'buildStatus'],
}
const implCommon = `${CTX}
You are implementing one step of an approved plan in the working tree at ${REPO} (edit files in place with Read/Edit/Write; other steps run before/after you, so touch ONLY your step's files). Match the house style exactly: file-header comments, invariant-explaining inline comments, Theme/Glass idioms. When done, run the build command and iterate until it passes. Return buildStatus green only if the build actually succeeded.
FULL PLAN (for context — execute only your step):
`
const step1 = await agent(`${implCommon}${plan}
YOUR STEP: STEP 1 — DATA (Models.swift + SupabaseManager.swift only).`, { label: 'impl:1-data', schema: IMPL_SCHEMA })
if (!step1 || step1.buildStatus !== 'green') throw new Error('Step 1 (data) failed: ' + (step1?.notes ?? 'agent lost'))
log(`Step 1 data: ${step1.filesChanged.join(', ')}`)

const step2 = await agent(`${implCommon}${plan}
ALREADY DONE — STEP 1: ${JSON.stringify(step1)}
YOUR STEP: STEP 2 — STATE (AppState.swift; you may make the minimal compile-keeping edits in views that reference deleted members ONLY if the build cannot otherwise pass, and note them for step 3).`, { label: 'impl:2-state', schema: IMPL_SCHEMA })
if (!step2 || step2.buildStatus !== 'green') throw new Error('Step 2 (state) failed: ' + (step2?.notes ?? 'agent lost'))
log(`Step 2 state: ${step2.filesChanged.join(', ')}`)

const step3 = await agent(`${implCommon}${plan}
ALREADY DONE — STEP 1: ${JSON.stringify(step1)}
ALREADY DONE — STEP 2: ${JSON.stringify(step2)}
YOUR STEP: STEP 3 — VIEWS (TeacherHomeView.swift, ReviewGradingView.swift, DevGalleryView.swift if needed).`, { label: 'impl:3-views', schema: IMPL_SCHEMA })
if (!step3 || step3.buildStatus !== 'green') throw new Error('Step 3 (views) failed: ' + (step3?.notes ?? 'agent lost'))
log(`Step 3 views: ${step3.filesChanged.join(', ')}`)

phase('Review')
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          description: { type: 'string' },
          suggestion: { type: 'string' },
        },
        required: ['title', 'file', 'severity', 'description'],
      },
    },
  },
  required: ['findings'],
}
const reviewCommon = `${CTX}
The change is implemented in the working tree. Inspect it with: cd ${REPO} && git diff (plus reading the changed files in full: Weft/Models.swift, Weft/SupabaseManager.swift, Weft/AppState.swift, Weft/TeacherHomeView.swift, Weft/ReviewGradingView.swift, Weft/DevGalleryView.swift). Report only findings you can ground in specific lines.`
const reviews = await pipeline(
  [
    { key: 'requirements', prompt: `${reviewCommon}
LENS — REQUIREMENTS: does the result deliver the spec + the user's direction? Classes-first two levels; Library global; live card = monitoring ONLY (no grading affordance on it); Sessions history per class with per-row Review essays that works for CLOSED sessions (the original defect); grading keys on an explicit session, never ambient liveSession; relaunch lands on the live class; one-live-session guard names the owning class. Flag anything missing or half-done.` },
    { key: 'correctness', prompt: `${reviewCommon}
LENS — CORRECTNESS: state lifecycle bugs. signOut resets every NEW member; dropMockData vs teacher mocks; signed-in user must NEVER see fake students/sessions (the bug that started this); preview (signed-out) must still demo both levels incl. one open + one closed mock session; endSession refreshes history and clears the right state; races (end while grading open; class switch mid-load; stale classSessions across classes); ExamSession decode tolerant for rows without created_at; no force unwraps.` },
    { key: 'ui-idiom', prompt: `${reviewCommon}
LENS — UI/IDIOM: does TeacherHomeView match the student-home + house idiom (GlassCard/Chip/Kicker/sectionHeader/Theme spacing/rowHover/linkPointer/error banner with Retry), back control + animation consistent, empty states present (no classes; no sessions yet; no live), comment style consistent with file headers, no dead code left from the Build/Live tabs?` },
  ],
  r => agent(r.prompt, { label: `review:${r.key}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (rev, orig) => parallel((rev?.findings ?? []).map(f => () =>
    agent(`${CTX}
A reviewer (${orig.key} lens) claims this about the working-tree change in ${REPO}:
TITLE: ${f.title}
FILE: ${f.file}
CLAIM: ${f.description}
Adversarially VERIFY by reading the actual code. Is it a real problem worth fixing now (not stylistic preference, not already handled elsewhere)? Default to isReal=false if uncertain.`, { label: `verify:${f.title.slice(0, 30)}`, phase: 'Review', schema: { type: 'object', properties: { isReal: { type: 'boolean' }, reasoning: { type: 'string' } }, required: ['isReal', 'reasoning'] } })
      .then(v => ({ ...f, lens: orig.key, verdict: v }))
  ))
)
const confirmed = reviews.filter(Boolean).flat().filter(Boolean).filter(f => f.verdict?.isReal)
log(`Review: ${confirmed.length} confirmed findings`)

let fixResult = null
if (confirmed.length > 0) {
  fixResult = await agent(`${CTX}
Fix the following CONFIRMED review findings in the working tree (Read/Edit in place, house style), then run the build command and iterate until green. Findings:
${JSON.stringify(confirmed, null, 2)}
Return buildStatus green only if the build actually succeeded.`, { label: 'fix:confirmed-findings', schema: IMPL_SCHEMA })
  if (!fixResult || fixResult.buildStatus !== 'green') throw new Error('Fix pass failed: ' + (fixResult?.notes ?? 'agent lost'))
}

return {
  plan,
  steps: [step1, step2, step3],
  confirmedFindings: confirmed.map(f => ({ title: f.title, file: f.file, severity: f.severity, lens: f.lens })),
  fixResult,
}