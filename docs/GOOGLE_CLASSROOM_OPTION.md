<!-- STATUS: PARKED. Founder decision 2026-09-16: the Google route is possible but not being built now. This memo is reference material produced by a sourced research workflow (wf_9728ef22-02d). -->

# Weft and Google: essay custody decision memo

Prepared for the founder. Date: 17 September 2026.

Scope note. Every research claim below carries a link to a page that was fetched and checked. Claims the research team could not verify (mostly DigiExam knowledge base pages that return HTTP 403 to automated fetches) are held back in section 7, "Needs confirmation", and are not used in the reasoning. Scores, arithmetic and design suggestions are my judgment and are labelled as such.

## 0. Bottom line

- DigiExam does not advertise any Google Classroom or Google Assignments integration. Its two integrations pages name seven LMSs and no Google product, its 212-article English knowledge base has zero hits for Google Classroom, Google Assignments, OneRoster, LTI 1.3 or LTI Advantage, exam papers leave it only as teacher-pulled PDFs, and there is no DigiExam listing in the Google Workspace Marketplace. "We deliver the essay into your Google Workspace and keep nothing" is unoccupied ground in this category.
- "Google Assignments" is not a destination. It is Google's own LTI tool for putting Docs and Drive inside Canvas, Schoology or Moodle. The route into a Google Classroom school is the Classroom API plus the Drive API.
- The API path exists and Google's own semantics help. The student's app writes the essay as a Drive file, attaches it to a Classroom submission, and calls turnIn, which "transfers ownership of attached Drive files to the teacher". After that the school owns the artifact inside its own Workspace and Weft holds only identifiers.
- Four hard gates: (1) only the Google Cloud project that created the coursework may modify its submissions, so teachers must create exams in Weft, never by hand in Classroom; (2) turnIn can only be called by the student, so every student needs Weft authorised on their own Google account, which for users designated under 18 requires the Workspace admin to configure Weft first; (3) never write to Google during the exam (the Docs API allows 600 writes per minute per project, and Classroom has had outages with no workaround), so the exam engine stays local-first; (4) Drive revisions are not a durable draft trail, so drafts are separate files.
- Recommendation: build option B (Google-resident essays, Weft keeps proctoring metadata only) on a local-first exam engine, reuse the E2EE work from the dormant branches for encryption at rest on the student Mac and for any transient buffer, and hold option C in reserve only if the school demands a vendor-side crash-recovery copy. Before committing, run one experiment (does Weft's drive.file access to the essay survive the ownership transfer at turnIn) and confirm with the school that every examined class exists as a Google Classroom course.

## 1. What DigiExam actually does with Google

Verified:

- DigiExam's integrations page lists exactly seven LMS integrations, Canvas, Moodle, itslearning, Blackboard, Sakai, Brightspace and Blackbaud, and names no Google product. Its LTI features are account provisioning with SSO ("The LTI integration automatically creates an account based on the role in the LMS and allows for Single Sign-On"), content import ("Supports QTI 1.2, Common Cartridge (IMSCC) and Content Package"), deep linking, and grade sync ("updated grades are automatically sent back to the LMS grade book"). Sources: https://www.digiexam.com/platform/integrations and https://www.digiexam.com/integrations
- Across all 212 English articles in DigiExam's Zendesk knowledge base (pulled through the help centre API, eight pages of 30), the strings classroom.google, Google Assignments, assignments.google, OneRoster, LTI 1.3, LTI Advantage, Names and Roles, and capitalised Classroom return zero matches. Three articles hit "classroom" in the physical sense ("monitored during the implementation by the teacher in the classroom"). Standalone "LTI" appears in 11 articles, including one titled "Enable LTI integration in Digiexam" that uses an OAuth Consumer Key and XML URL, which is the legacy LTI 1.1 configuration shape. Source: https://support.digiexam.se/api/v2/help_center/en-us/articles.json
- Student exam papers leave DigiExam only by a teacher-initiated PDF pull: "Cloud print" ("our most up-to-date version for printing, where a PDF is sent to your email"), a zip "containing the student exam papers as individual PDF documents", or a single PDF "containing all student exam papers in the exam". No Google Drive or Classroom destination is offered. Source: https://support.digiexam.se/hc/en-us/articles/8476726498076-Print-Download-student-exam-papers-as-PDF (read through the help centre JSON endpoint because the HTML returns 403)
- A Google Workspace Marketplace search for "digiexam" returns "No matching results" (a control search for Kami returned real app cards). Source: https://workspace.google.com/marketplace/search/digiexam
- The Edu App Center LTI directory entry for DigiExam lists category tags and a "Consumer Key and Secret" requirement, no LTI version and no mention of Google. Weak evidence on its own because parts of the page are unrendered placeholders. Source: https://www.eduappcenter.com/apps/626
- Third-party directories that claim a Google Classroom integration for DigiExam are not backed by their own pages: softwarefinder lists five LMSs and no Google product, with no citation. Source: https://softwarefinder.com/lms/digiexam

What this means. DigiExam's Google surface, as far as any fetched page shows, is nothing. The defensible sentence for a sales conversation is "DigiExam does not advertise a Google Classroom or Google Assignments integration and offers no Drive or Classroom destination for exam papers", not "DigiExam cannot integrate with Google". The SAML SSO setup and LTI 1.1 details the research team expected to find sit on knowledge base pages that returned 403, so they are in section 7 and not relied on here.

Category context:

- Exam.net does integrate with Google Classroom, but the integration is Google sign-in for exam access, "With one click, students receive their results directly in Google Classroom", and grading with "Google Classroom's built-in tools for rubrics, comments, and insights". It makes no claim to deliver exam content or student answers into Google. Source: https://exam.net/streamline-exam-workflow-with-lms-integration
- Google Assignments ("Assignments LTI") is "an add-on application for learning management systems (LMSs)" used as an LTI tool "integrated within Instructure Canvas, PowerSchool Schoology Learning, or Moodle"; the page describes no mechanism for a third party to deliver into it. Source: https://support.google.com/edu/assignments/answer/9069054 . It is built on LTI 1.3 and Canvas customers have needed the LTI 1.3 tool since August 2023 (Google Apps LTI end of life 2024). Source: https://www.instructure.com/resources/blog/collaboration-theme-new-canvas-integrations-google-google-assignments-lti-13-update
- Google Classroom "does not support LTI 1.3 (Learning Tools Interoperability) or LTI Advantage"; integration is through its API plus Google SSO, and Assignments' Drive-backed LTI resources "can't be turned into LTI resources in Google Classroom". Source (third party, Edlink): https://ed.link/community/does-google-support-lti-1-3-lti-advantage/ . Google's own developer page says Classroom add-ons and LTI tools "are not directly compatible". Source: https://developers.google.com/workspace/classroom/add-ons/get-started/addons-lti-comparison
- Google's own lockdown answer does not cover Macs. Forms locked mode needs "A Google Workspace for Education Account", "A Chromebook managed by your school for each student" and "Chrome OS 75 and up". Source: https://support.google.com/docs/answer/7634943 . On Macs, Weft is the locked editor and Google is the store; the two are complementary, not competing.
- Precedents for the "it lands in your Drive" pitch exist outside exams. Brisk markets "Everything you create with Brisk saves directly to Google Drive, with no exporting or copying needed". Source: https://www.briskteaching.com/use-cases/google-teachers . Google's originality reports use "a private, school-owned repository of their student work" on the school's Drive and Google "doesn't store student work to check against external domains". Source: https://support.google.com/edu/classroom/answer/9424252 . The cautionary precedent is Kami, whose policy says "Kami does not store these files once the sharing process is completed" while "Annotations made by users are stored on the site". A privacy officer will look for exactly that kind of gap in Weft's claim. Source: https://www.kamiapp.com/privacy-policy/

## 2. The Classroom and Drive API path

### 2.1 The rule that shapes everything: coursework ownership

courses.courseWork.create: "The resulting course work (and corresponding student submissions) are associated with the Developer Console project of the OAuth client ID used to make the request. Classroom API requests to modify course work and student submissions must be made with an OAuth client ID from the associated Developer Console project." Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork/create

The same restriction is restated on modifyAttachments, turnIn and patch (linked below), and a grade patch from the wrong project fails with PERMISSION_DENIED "if the requesting developer project did not create the corresponding course work". Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/patch

Consequences:

1. Weft must create every Classroom assignment it will ever attach an essay to or write a grade into. An assignment a teacher creates by hand in the Classroom UI is not associated with Weft's project; Weft can read it but never attach to it or grade it.
2. Weft's Google Cloud project is a permanent identity. Every assignment Weft ever creates is bound to it. Do not create it casually, do not let it lapse, and plan for it to outlive the current codebase.
3. The teacher workflow is "start the exam in Weft". Weft's UI should never offer "attach to an existing Classroom assignment".

### 2.2 Actors, tokens, scopes

Two OAuth identities, both under Weft's single Cloud project and OAuth client.

Teacher (Weft teacher app, teacher's Google account):

- Read the roster: courses.students.list, "Returns a list of students of this course that the requester is permitted to view", under classroom.rosters or classroom.rosters.readonly (the method also accepts classroom.profile.emails and classroom.profile.photos); "The default is 30 if unspecified", so paginate. Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.students/list
- Create the assignment: courses.courseWork.create (the reference page lists classroom.coursework.students as its scope; the finding that stated this was rejected on an unrelated clause about mandatory fields, so confirm on the page). Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork/create
- Write grades: courses.courseWork.studentSubmissions.patch, "The following fields may be specified by teachers: draftGrade, assignedGrade". Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/patch . draftGrade "is only visible to and modifiable by course teachers". Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions
- A courses list scope is also needed to pick the course; its exact name was not in the fetched material (section 7).

Student (Weft student app on the exam Mac, student's own Google account):

- classroom.coursework.me, the only scope the turnIn page lists. Source: https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/turnIn
- drive.file, which Google lists under recommended non-sensitive scopes: "Create new Drive files, or modify existing files, that you open with an app or that the user shares with an app while using the Google Picker API or the app's file picker". Source: https://developers.google.com/workspace/drive/api/guides/api-specific-auth

Never request drive, drive.readonly, drive.metadata or drive.metadata.readonly. All four are restricted scopes on the same page, and restricted scopes require "an annual security assessment from a Google empanelled group of security assessors" ( https://support.google.com/cloud/answer/13464321 ), re-run "at least every 12 months" under CASA ( https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification ). Google's own guidance: "choose the most narrowly focused scope possible and avoid requesting scopes that your app doesn't require" ( https://developers.google.com/workspace/classroom/guides/auth ).

Why the student token, and why the calls run on the student's Mac. turnIn "may only be called by the student that owns the specified student submission" (turnIn page above). There is no teacher-side or admin-side turn-in. If the Drive upload, the attach and the turn-in run inside the native app with the student's token held in the macOS Keychain, the essay text never transits a Weft server, and Weft's server never holds a Google token. That is the only architecture in which "we don't store the essays" is literally true rather than "we delete them quickly". (Design reasoning, not a sourced claim.)

Domain-wide delegation is the alternative to per-student consent: a super admin grants a client ID plus scope list "permission to access data of users within their domain without requiring a specific user's consent" ( https://developers.google.com/workspace/classroom/guides/key-concepts/domain-wide-delegation ; admin side: https://knowledge.workspace.google.com/admin/apps/control-api-access-with-domain-wide-delegation ). Google's own page says "It's recommended that you avoid using domain-wide delegation if possible." Do not lead with it; it contradicts a data-minimisation pitch. Whether a delegated service account impersonating the student satisfies turnIn's owner check is untested (section 7).

### 2.3 The sequence

Before the exam (teacher app, teacher token):

1. Teacher signs in with Google. Weft lists the teacher's Classroom courses and pulls the roster with courses.students.list (paginate past 30).
2. Teacher creates the exam in Weft. Weft calls courses.courseWork.create with workType ASSIGNMENT, because attachments "may only be added to student submissions belonging to course work objects with a workType of ASSIGNMENT" ( https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/modifyAttachments ). Weft stores courseId and courseWorkId. The assignment is now bound to Weft's project.
3. Weft re-pulls the roster when the exam is opened on exam day (design practice; a stale roster means a student without a seat).

Before the exam (student, once, days ahead): the student signs into the Weft student app with Google and grants classroom.coursework.me and drive.file. If the admin has not configured Weft, users designated under 18 are blocked and see "Access blocked: Your institution's administrator needs to review [app name]" (sources in 2.4). Do the authorisation check days before the first exam, not at the bell, and on the Mac the student will actually sit at; on shared lab Macs, authorise at seat time before lockdown engages.

During the exam (student Mac, no network required):

4. Locked full-screen editor, autosave to an encrypted local container every few seconds, as Weft does today. No Google writes. Reasons: Docs API write limits are 600 requests per minute per project and 60 per minute per user per project ( https://developers.google.com/workspace/docs/api/limits ), which at a ten-second autosave interval is exhausted by roughly 100 concurrent students (my arithmetic: 600 divided by 6 writes per minute per student); exceeding Docs quota "is planned to incur charges to your Google Cloud billing account later in 2026" (same page); and Classroom has had outages with "None at this time" as the workaround, including 1 hour 53 minutes on 9 June 2025 caused by a database schema change that pushed clusters to 100 percent CPU ( https://www.google.com/appsstatus/dashboard/incidents/KjFLjecwg9xeewnUYjh1 ) and an access incident on 29 April 2026 with "No workarounds available at this time" ( https://www.google.com/appsstatus/dashboard/incidents/GDxbSoojBb9yyEhU2Cua ).

At hand-in (student Mac, student token, from a durable local outbox):

5. Seal. The app freezes the text, renders a PDF (the sealed exam record), optionally a Google Doc or .docx copy for teacher comments, and computes a SHA-256 of the sealed PDF. The student sees "submitted" as soon as the sealed copy is on local disk and in the outbox; Google delivery is asynchronous.
6. Drive create. The app creates the file(s) in the student's own Drive under drive.file with the Drive API file-creation call (files.create with a media upload; confirm the upload variant and its quota unit cost on the Drive reference). Note that "any newly created Google Docs, Sheets, Slides, Drawings, Forms, or Jamboard files count toward storage" since 2 May 2022 ( https://workspaceupdates.googleblog.com/2021/04/changes-to-google-workspace-storage.html ), so the Google Doc format has no storage advantage over PDF.
7. Attach. The app looks up its own submission on Weft's coursework and calls courses.courseWork.studentSubmissions.modifyAttachments to add the Drive file(s). Constraints: "This request must be made by the Developer Console project of the OAuth client ID used to create the corresponding course work item"; "A student submission may not have more than 20 attachments"; ASSIGNMENT only; "Form attachments are not supported". Source: modifyAttachments page above.
8. Turn in. courses.courseWork.studentSubmissions.turnIn as the student. "Turning in a student submission transfers ownership of attached Drive files to the teacher and may also update the submission state." Source: turnIn page above. Custody has now passed to the school.
9. Confirm and record. Read the submission back, then Weft's server records identifiers and integrity data only: courseId, courseWorkId, submissionId, Drive fileId(s), timestamps, the SHA-256, and the proctoring events (2.7). No essay text, ever.
10. Local clean-up. The student's local encrypted copy is purged after a fixed window (for example seven days after confirmed delivery) or on teacher confirmation. Write the number down.

After the exam (teacher app, teacher token):

11. Grading. Weft writes draftGrade during marking (teacher-only visibility) and assignedGrade on release, through studentSubmissions.patch from Weft's project. Whether the teacher's Weft app can read the essay from Drive after the ownership transfer under drive.file is the open experiment (section 7). Sourced fallbacks: the teacher opens the file through Google Picker inside the Weft teacher app, which is explicitly within drive.file ("files that the user shares with an app while using the Google Picker API"), or grades inside Classroom itself, where the attachment already sits.

Retries. Drive returns "403: User rate limit exceeded" or "429: Rate limit exceeded" and Google says to "use an exponential backoff algorithm" with wait time min(((2^n)+random_number_milliseconds), maximum_backoff) ( https://developers.google.com/workspace/drive/api/guides/limits ); Classroom returns RESOURCE_EXHAUSTED, to be retried "preferably using exponential backoff" ( https://developers.google.com/workspace/classroom/reference/limits ). Steps 6 to 9 must be idempotent in the outbox: persist the fileId the moment step 6 succeeds so a retry never creates a second file.

### 2.4 Admin steps on the school side

All of these fall on the Workspace admin, not on Weft, and they take calendar time.

1. Configure Weft's OAuth client ID under third-party app access, as Trusted ("Can access all Google services (both restricted and unrestricted)") or, better for the pitch, as Specific Google data ("Can request data access only to scopes that you specify when configuring the app"), listing exactly the scopes in 2.2. Source: https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data
2. "Users designated as under 18 by the age-based access setting are blocked from using unconfigured third-party apps"; the admin must open the app and click Configure access, confirming parental consent as part of that step. "For users under the age of 18, your organization is responsible for obtaining parental consent, if required by applicable law, before allowing these users to access third-party apps." "This feature is available only with Google Workspace for Education editions." Source: https://knowledge.workspace.google.com/admin/getting-started/editions/manage-access-to-unconfigured-third-party-apps-for-users-designated-as-under-18 . The Education Terms say the same at contract level: the Customer "will, before allowing any such End User to access or use those products or offerings, obtain parental consent for the collection and use of personal information", for Third-Party Offerings "to the extent required by applicable law". Source: https://workspace.google.com/terms/education_terms/
3. If the school uses Context-Aware Access, the admin can allowlist Weft's OAuth client ID "to maintain Application Programming Interface (API) access to Google Workspace services even when those services have Context-Aware Access policies that apply to API access". Source: control-which-apps page above.
4. Since December 2024 admins can limit an app to specific OAuth scopes, which "prevents apps from gaining additional access without admin consent, even if they request new API scopes in the future". Fix the scope list now; any later scope addition is a re-approval event with the school. Source: https://workspaceupdates.googleblog.com/2024/12/configure-third-party-apps-by-select-api-scopes-general-availability.html
5. Errors that mean a step was missed: "Error 400: access_not_configured", "Error 400: admin_policy_enforced", and the student-facing "Access blocked: Your institution's administrator needs to review [app name]" with a request-access button that "lets your administrator review the third-party application". Sources: https://developers.google.com/workspace/classroom/best-practices/access-control-enhancements and https://support.google.com/edu/classroom/answer/11081157

The Education Terms also settle two contractual points for the admin packet: "Customer retains all Intellectual Property Rights in Customer Data" (section 5.1), and "Any use of Third-Party Offerings is subject to separate terms and policies with the relevant service provider", so the school's Google agreement does not cover Weft and Weft's own DPA carries the load. Source: https://workspace.google.com/terms/education_terms/

### 2.5 Weft-side prerequisites

- Publish the OAuth consent screen before any pilot. In Testing status, "Authorizations by a test user will expire seven days from the time of consent" and a refresh token "will also expire". That looks like a random exam-day auth failure a week after a successful demo. Source: https://support.google.com/cloud/answer/15549945
- Verification. With only sensitive scopes, OAuth verification "typically requires 3-5 working days"; a Marketplace listing adds a review for which "We recommend budgeting 2-3 weeks"; "Reviewers may connect to your application from Argentina, Canada, and the United States", so do not geo-block them. Source: https://developers.google.com/workspace/classroom/add-ons/developer-guides/review-process-overview . A developer forum thread records schools waiting three and five months for Google Workspace for Education tenant approvals; that is a different queue from app verification, but it signals that Google education-side timelines slip. Source: https://discuss.google.dev/t/google-education-approval-delay-waiting-for-3-months/260303
- Do not build a Classroom add-on for this. Add-ons "are available to all teachers with Teaching & Learning or Plus Google Workspace for Education licenses" and "open third-party content in iframes in Google Classroom" ( https://developers.google.com/workspace/classroom/add-ons ; the licence requirement is also stated at https://support.google.com/edu/classroom/answer/12234529 and https://support.google.com/edu/classroom/answer/12351654 ). A locked native macOS editor cannot be an iframe. The add-on model does offer a student_work_review_uri "where an instructor can view and grade the work from a particular student" ( https://developers.google.com/workspace/classroom/add-ons/get-started/addons-lti-comparison ), and has "the submissionId and attachmentId ... stored by the add-on developer" ( https://developers.google.com/workspace/classroom/add-ons/developer-guides/attachment-interactions ), but it buys nothing the plain API does not, and it is gated on a licence the school may not hold.

### 2.6 Quotas and exam-day arithmetic

Sourced limits:

- Classroom API: "Queries per day per client: 4,000,000", "Queries per minute per client: 3,000", "Queries per minute per user: 1,200", and "Quota is checked on a 60-second moving average, which allows for spikes in usage". Sources: https://developers.google.com/workspace/classroom/limits and https://developers.google.com/workspace/classroom/reference/limits
- Drive API: "Per minute per project: 1,000,000 quota units" and "Per minute per user per project: 325,000 quota units". Source: https://developers.google.com/workspace/drive/api/guides/limits
- Docs API: 600 write requests per minute per project, 60 per minute per user per project. Source: https://developers.google.com/workspace/docs/api/limits

My arithmetic, not Google's: a 30-student class handing in within one minute is about 90 Classroom calls (attach, turn in, read back) plus 30 to 60 Drive calls; a 300-student year group in the same minute is about 900 Classroom calls. Both sit under 3,000 per minute per client and are smoothed by the moving average. The per-user limit is irrelevant at three or four calls per student. The only design that hits a quota is live autosave into Google Docs, which is why there is none.

### 2.7 What Weft retains under this design

Publish this list; it is what makes "we don't store the essays" auditable.

- Identifiers: Google course, coursework, submission and Drive file IDs; student and teacher Google user IDs; Weft exam and assignment IDs.
- Integrity data: hand-in timestamp, SHA-256 of the sealed PDF, word-count curve, focus-loss and paste-attempt events (counts and sizes, never contents), app version, device identifier.
- Grades written to Classroom (draft and assigned).
- Never: essay text, keystroke-level logs (a keystroke log reconstructs the essay and would be content in disguise), or Drive file contents.

## 3. Three options compared

Option A: zero-knowledge E2EE on Weft's own storage (the design on the dormant branches). Weft stores ciphertext; keys live with the school or the teacher; Weft cannot read essays but does hold them.

Option B: Google-resident essays. Local-first exam, delivery into the school's Classroom and Drive at hand-in through the sequence in 2.3, Weft keeps only the metadata in 2.7.

Option C: hybrid. B, plus a transient encrypted server copy during the exam for crash recovery, deleted after confirmed delivery. To be honest about what C is, the transient copy should be ciphertext under the E2EE keys from A, written every few seconds during the exam, deleted on confirmed turnIn (state read-back, not a timer), with a hard cap (for example 24 hours) if delivery never confirms, and both numbers in the DPA.

Scores are my judgment on a 1 to 5 scale (5 = best on that criterion; for build effort, 5 = least effort). The facts under each score are cited in sections 1 and 2.

| Criterion | A: E2EE on Weft storage | B: Google-resident | C: Hybrid |
|---|---|---|---|
| School trust | 3. Vendor still stores essays; "encrypted" is a promise the school must audit. | 5. School owns the artifact in its own Workspace through turnIn; "Customer retains all Intellectual Property Rights in Customer Data". | 4. Strong at rest, but the transient copy is a retention window that has to be a number in the DPA (the Kami lesson). |
| Build effort | 4. Partly designed; key management, recovery and grading-with-decryption still to build. | 3. OAuth in a native app, Classroom and Drive calls, outbox, metadata model, admin packet, verification, one experiment. | 2. Everything in B plus a transient store, deletion proofs and the E2EE key handling from A. |
| Exam-day reliability | 4. Local-first; delivery to Weft's own server, which Weft controls; server copy allows recovery if a Mac dies. | 3, rising to 4 with a tested recovery path. Local-first; delivery depends on Google, which has documented outages; no vendor-side copy if a Mac dies before delivery. | 4. Local-first; transient server copy covers a dead Mac; delivery still depends on Google. |
| Offline resilience | 4. Exam runs offline; queued delivery. | 4. Exam runs offline; queued delivery. Google's own Docs offline is not involved and would not survive a locked native app anyway (it needs the Docs Offline extension, the Drive offline setting, Chrome or Edge, no private browsing, one account per profile: https://support.google.com/docs/answer/6388102 ). | 4. Same, plus best-effort transient sync. |
| Grading UX | 5. Teacher app decrypts and renders; full control of the grading surface, diff and comments. | 3. Grade write-back is solid (draftGrade then assignedGrade); reading the essay inside Weft after ownership transfer is the open experiment; fallbacks are Picker or grading in Classroom. | 3. Same as B once the transient copy is deleted; grading inside the window would stretch "transient". |
| Draft versioning | 5. Versions are rows in Weft's store. | 3. Works: separate files, one assignment per stage, Weft metadata, client-side diff; more moving parts and the same read-access dependency. | 3. As B. |
| Unweighted total | 25 | 21 (23 with recovery path) | 20 |

How to read the table. On engineering convenience A wins, because holding the data always makes the product easier to build. On the one criterion the founder named as the end goal, school trust, A cannot score 5 no matter how good the cryptography is, because the school's question is "do you store our essays" and the honest answer under A is "yes, encrypted". B is the only option whose honest answer is "no". C turns "no" into "for N minutes", and N has to be defended in every procurement conversation. Two sourced facts push the same way: the NY model Parents' Bill of Rights puts a duty on the district to "minimize the collection, processing, and/or transmission of student personal data to vendors" ( https://classsizematters.org/wp-content/uploads/2025/10/model-PBOR-rev.-10.21.25.pdf ), and vendors that hold student data draw public critiques of the kind EFF published on GoGuardian ( https://www.eff.org/deeplinks/2023/10/how-goguardian-invades-student-privacy ).

One product implication of B to say out loud: if the drive.file experiment fails and teachers grade inside Classroom, Weft's value shifts from "grading surface" to "locked editor, integrity record, custody handoff and draft trail". That is a stronger position against DigiExam than a grading UI is, but it is a different product story and should be chosen, not stumbled into.

## 4. The draft trail under option B

The school contact's ask: draft 1, draft 2, final, linked per student, with a per-student toggle between drafts and a diff.

Data model (Weft side, metadata only):

- assignment_group: {id, courseId, title, stages: [draft1, draft2, final]}
- stage: {courseWorkId (one Classroom assignment per stage, created by Weft), dueDate, order}
- delivery: {studentGoogleId, stage, submissionId, driveFileId(s), sha256, deliveredAt, revision_of: the previous stage's driveFileId}

Why separate Drive files, not Drive revisions. Google's own Drive documentation says "The list of revisions returned by this method might be incomplete for files with a large revision history, including frequently edited Google Docs, Google Sheets, and Google Slides", "Purgeable revisions are typically preserved for 30 days, but can be purged earlier if a file has 100 revisions that aren't designated as 'Keep Forever' and a new revision is uploaded", and "Up to 200 revisions can be set to 'Keep Forever' and they count towards your storage limit". Source: https://developers.google.com/workspace/drive/api/guides/manage-revisions . A draft that lives only as a revision is not durable evidence.

Why one Classroom assignment per stage rather than one assignment with three attachments. turnIn is a one-shot custody transfer, and one assignment per stage gives the school separate due dates and separate draft and assigned grades per stage. The alternative (one assignment, up to 20 attachments) exists if the school wants a single gradebook column, but it requires the student to reclaim and re-turn-in, and whether modifyAttachments works after turnIn was not verified (section 7). Default to one assignment per stage; offer the other on request.

How each stage is delivered: exactly the sequence in 2.3, once per stage. Each stage's file is named with the student's name, the assignment and the stage, mirroring what Google Assignments does: "Each distributed copy will be labeled with a student's name and organized in a Drive folder" ( https://support.google.com/edu/assignments/answer/9069054 ), and in Assignments LTI the copies live in "an automatically created course folder inside the student's Drive Assignments folder", "File ownership transfers to the instructor" on submission and "File ownership transfers back to the student" on return ( https://support.google.com/edu/assignments/answer/9433485 ). Those are Assignments LTI semantics, not Classroom API semantics: for the Classroom API, only the turnIn transfer to the teacher is verified; where the file appears in the teacher's Drive, whether the student keeps view access, and what return does to ownership are in section 7.

Per-student toggle. In the Weft teacher app, each student row carries a Draft 1 / Draft 2 / Final control. Selecting a stage fetches that stage's file by driveFileId with the teacher's token and renders it. Nothing is cached on Weft's server.

Diff. Computed client-side in the teacher app, word level, between any two stages the teacher selects; never stored. Two ways to get the text: (1) the teacher's token reading the teacher-owned file under drive.file, pending the experiment; (2) if that fails, the student app computes the diff at delivery of stage n against its local copy of stage n-1 and delivers it as an extra attachment (an HTML or PDF file) in the same submission, which makes the diff Google-resident and independent of teacher-side read access. Path (2) requires keeping the previous stage's local encrypted copy on the student's Mac until the next stage is delivered; that is a retention decision to write down, but it sits on school-owned hardware, not on Weft.

Process evidence. Teachers already read Google Docs version history as evidence of process: "A real student writing sample should have lots of entries" while AI-generated text "will have very few entries and text will appear all at once" ( https://www.eastcentral.edu/free/ai-faculty-resources/using-google-docs-to-detect-ai/ ). A file Weft uploads at hand-in will, by construction, appear in Drive as a single event (my inference from how the upload works, not a fetched statement), which is exactly the signature teachers read as a paste. So deliver Weft's own process artifact (a rendered timeline: word count over time, pauses, paste events) as a third attachment next to the essay, labelled as a factual record and not a score.

What Classroom shows without Weft. Each stage is an ordinary assignment with the file attached, so a teacher can open Draft 1 and Draft 2 side by side in Classroom or Drive with no Weft involvement at all. The Weft toggle and diff are conveniences layered on top, not a dependency.

## 5. Failure modes and mitigations

1. Teacher creates the assignment by hand in Classroom. Weft's project did not create it; attach and grade calls fail with PERMISSION_DENIED (2.1). Mitigation: Weft is the only creation surface; no "link existing assignment" affordance; onboarding says why.
2. Student is blocked at sign-in. Under-18 users are blocked from unconfigured apps; errors access_not_configured, admin_policy_enforced, "Access blocked" (2.4). Mitigation: admin configuration and parental consent are pilot gates; run an authorisation check with every student days before the first exam; the teacher app shows who has not authorised.
3. Tokens die a week after the demo. Testing-status consent screens expire authorisations in seven days (2.5). Mitigation: publish the consent screen and complete verification before the pilot.
4. Google is down at hand-in. Classroom outages with no workaround are on record (2.3). Mitigation: local seal first, "submitted" shown on local success, durable outbox with exponential backoff, teacher-visible pending-delivery count, delivery completes later without teacher action.
5. Rate limits. 403 and 429 from Drive, RESOURCE_EXHAUSTED from Classroom (2.3). Mitigation: backoff, idempotent outbox; the arithmetic in 2.6 shows headroom; never autosave to Docs.
6. A student's Mac dies before delivery and Weft holds nothing. Mitigations, in order of preference: (a) local encrypted autosave survives app crashes and reboots; (b) a LAN mirror of the encrypted in-progress copy to the proctoring teacher's Mac in the room, which is school hardware, not Weft storage (design idea, untested); (c) a low-frequency encrypted checkpoint file in the student's own Drive under drive.file, best effort and never blocking, which keeps the recovery copy inside the school's tenancy (Drive API quota applies, not the Docs API cap; per-call unit cost to confirm; the app deletes the checkpoint after delivery); (d) option C's transient server copy with a numeric window. Choose (b) or (c) before falling back to (d).
7. Student Drive over quota. Docs count toward storage since 2022 (2.3); the exact hard-stop behaviour for per-user limits is in section 7 pending confirmation. Mitigation: a failed Drive create lands in the outbox and the teacher's pending list; ask the admin what per-student limits are set; do not design around a shared drive as a workaround, because the research could not confirm that shared-drive content bypasses a student's personal limit.
8. Scope creep breaks the school's approval. Scope-level admin configuration blocks new scopes (2.4). Mitigation: freeze the scope list; treat any addition as a release blocker that goes through the school's admin.
9. Retention ambiguity. Kami says it keeps no files but keeps annotations (section 1). Mitigation: publish the 2.7 list; make every window a number; keystroke logs never leave the student's Mac except as the delivered process artifact.
10. Teacher cannot read the essay in Weft after turnIn. Unknown until tested (section 7). Mitigation: run the experiment first; Picker and grading-in-Classroom are the sourced fallbacks; the product still works, it grades in Google's UI.
11. Roster drift. A student added to the Classroom course after Weft imported the roster has no seat. Mitigation: re-pull the roster at exam open; teacher-side manual add path.
12. The Cloud project is lost or replaced. All coursework Weft created becomes unmodifiable by the new project (2.1). Mitigation: treat the project as a permanent asset with owner redundancy and no deletion rights on the day-to-day account.
13. Verification stalls. 3 to 5 working days is Google's number; education-side queues have run months (2.5). Mitigation: submit verification as soon as there is a build to film; use the test-user allowlist for internal demos only, never for a real exam.
14. Domain-wide delegation gets asked for by the district. Google discourages it (2.2). Mitigation: keep per-student OAuth as the design; if the district insists, scope the delegation to exactly the scopes in 2.2 and test the turnIn owner check before agreeing.

## 6. Recommendation and blockers

Recommendation. Commit to option B as the target architecture for this school, built on a local-first exam engine, with the E2EE work from the dormant branches reused for encryption at rest on the student Mac and for any transient buffer, and with option C held in reserve only if the school explicitly requires a vendor-side crash-recovery copy, in which case the retention window is written into the DPA as a number and the deletion trigger is confirmed turnIn, not a timer. Do not ship option A as the primary path for a Google Workspace school: it keeps Weft as the custodian and forfeits the one claim the incumbent cannot match.

Sequence:

1. This week: create the permanent Cloud project and OAuth client; freeze the scope list (2.2); publish the consent screen; start verification as soon as there is a build to film.
2. Run the experiment that decides the grading surface: after turnIn transfers ownership to the teacher, can the teacher's Weft app read the file under drive.file? Half a day in a sandbox tenant. In the same session test whether Drive appProperties written by Weft survive the transfer, whether a student can reclaim and edit an exam submission after turnIn, and whether modifyAttachments works after turnIn.
3. Build the delivery outbox and the metadata model from 2.7 and section 4 before touching UI.
4. Prepare the admin packet: OAuth client ID, scope list with a one-line justification per scope, Admin console steps with screenshots, parental-consent template text, the 2.7 retention list, and Weft's DPA.
5. Pilot with one class and one assignment group (draft 1, final), with the LAN-mirror or Drive-checkpoint recovery path tested in a dry run.

Blockers to confirm with the school before the design is final:

1. Does every class that would sit a Weft exam exist as a Google Classroom course with a maintained roster? If not, the Classroom half of B is unavailable for those classes and only a Drive-only fallback remains, which loses the ownership transfer at turnIn.
2. Which Google Workspace for Education edition does the school hold (Fundamentals, Standard, Teaching and Learning, Plus)? Add-ons need Plus or Teaching and Learning; the plain Classroom API pages we read state no edition restriction, but that absence was not confirmed as licensing fact.
3. Will the Workspace admin configure Weft's OAuth client (Specific Google data with the exact scopes) and run the under-18 parental consent process, and on what timeline?
4. Will teachers accept that exams are created in Weft and never by hand in Classroom?
5. Where do grades need to land: Classroom's gradebook (draftGrade then assignedGrade), an SIS, or both?
6. Where do teachers want to grade: inside Weft, or inside Classroom and Docs with Weft writing the grade?
7. Is a recovery copy on the proctoring teacher's Mac or in the student's own Drive acceptable, or does the school expect a vendor-held copy during the exam?
8. What per-student Drive storage limits has the admin set?
9. What did the contact mean by "Google Assignments": the Assignments LTI product (Canvas, Schoology, Moodle) or ordinary Classroom assignments?
10. Which DPA template does the school use, and does its existing DigiExam agreement set retention or export terms Weft must match?
11. Draft feature shape: one gradebook column per stage (default) or one column with multiple attachments?
12. Is the school's DigiExam linked to any LMS today, or run standalone with Google sign-in? This calibrates how much of B is net new for them.

## 7. Needs confirmation

Findings the research team could not verify against a fetched page, grouped by area, with what the checker found. None of them is used in the reasoning above.

DigiExam knowledge base (every page returned HTTP 403 to automated fetches; search snippets exist but are not sources):

- Google Workspace SSO is a hand-built custom SAML app with ACS URLs at app.digiexam.com and app-us.digiexam.com; roles ride on custom attributes. https://support.digiexam.se/hc/en-us/articles/360008095933-Google-Workspace-setup-formerly-G-Suite
- Separate EU and US instances (app-us.digiexam.com). Same page.
- LMS integration is LTI 1.1 (OAuth Consumer Key, OAuth Secret Key, XML URL). https://support.digiexam.se/hc/en-us/articles/211897665-Enable-LTI-integration-in-Digiexam (the knowledge base corpus grep does confirm an article of that title using those fields)
- Canvas: only score plus feedback cross the LTI boundary; the teacher must retype max points. https://support.digiexam.se/hc/en-us/articles/115002036669-Canvas-Schedule-an-exam
- Canvas: "Send your students' published grades and feedback to your LMS" checkbox at publish time. https://support.digiexam.se/hc/en-us/articles/115001449285-Canvas-Publish-an-exam
- Canvas students must launch back into DigiExam to see their answers. https://support.digiexam.se/hc/en-us/articles/115001449665-Canvas-Viewing-results-and-feedback
- Results are published to student accounts in DigiExam; unpublish revokes access. https://support.digiexam.se/hc/en-us/articles/115003661945-Publish-results-and-feedback
- Student self-service export is browser print to PDF. https://support.digiexam.se/hc/en-us/articles/4403792779794-Download-my-exam-results-as-PDF-as-a-student
- Drive used only inbound, for stimulus links shared "Anyone with the link". https://support.digiexam.se/hc/en-us/articles/115004490853-Media-links
- Excel grade export. https://support.digiexam.se/hc/en-us/articles/204873672-Checklist-for-Administrators
- QTI is import only. https://support.digiexam.se/hc/en-us/articles/9956187390876-Create-and-convert-QTI-files
- Sakai roster and grade-column checkboxes. https://support.digiexam.se/hc/en-us/articles/360019580754-Installation-guide-Sakai-LMS
- 2026 platform updates mention Google only as ChromeOS kiosk changes. https://support.digiexam.se/hc/en-us/articles/17522561788700-Platform-updates-2026
- Offline exam file on USB, local save alongside server save. https://support.digiexam.se/hc/en-us/articles/4408680188050-Offline-exam-file
- DigiExam markets full offline operation after exam start. https://www.digiexam.com/platform-overview . The checker fetched this page and found no occurrence of "offline" or "internet"; it markets security and integrity ("the most secure exam platform"), lockdown, classroom management and proctoring. Do not attribute an offline claim to DigiExam until a page states it.

Google Assignments and Classroom:

- Assignments is "a separate product from Classroom" and "not a thing you use inside Classroom": Google's page never mentions Classroom; the point rests on Edlink plus Google's "not directly compatible" wording. https://support.google.com/edu/assignments/answer/9069054
- Assignments LTI supports "LTI 1.1 or higher": not on the page. Same URL.
- Workspace LTI targets: https://edu.google.com/intl/ALL_us/workspace-lti/ lists Canvas and Schoology only, while the Assignments help page adds Moodle.
- Classroom shows a Resubmissions column in the student work table: not on the page fetched. https://support.google.com/edu/classroom/answer/6020285
- Returning a submission transfers ownership back to the student under the Classroom API: the return method page was not read; only the Assignments LTI help page says this, for Assignments.
- Whether a student keeps view access to the file after turnIn under the Classroom API, and where the file appears in the teacher's Drive: not researched.

Classroom API details:

- "Student submissions may only be modified by the Developer Console project that created the corresponding CourseWork resource" is verbatim on https://developers.google.com/workspace/classroom/guides/manage-coursework , with an associatedWithDeveloper field on submissions; the finding was rejected only because it called teacher-made assignments "permanently unreachable" (they are readable, just not writable).
- courseWork.create scope classroom.coursework.students and the request body: the checker confirmed the scope text but rejected the finding's "only title and workType mandatory" clause. https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork/create
- Submission state enum (CREATED, TURNED_IN, RETURNED, RECLAIMED_BY_STUDENT, STUDENT_EDITED_AFTER_TURN_IN): names confirmed, but state is read-only and STUDENT_EDITED_AFTER_TURN_IN is "only used by Questions". https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions
- Sensitive-versus-restricted verification table naming drive.file and Classroom scopes: the page has the tiers but names neither scope. https://developers.google.com/workspace/guides/configure-oauth-consent
- Roster scopes are sensitive and verification needs a demo video: "sensitive" is on the page, "video" is not. https://developers.google.com/workspace/classroom/tutorials/import-rosters
- "Any Classroom app touching user data must be verified or users see an unverified app warning": the page limits it to public apps with certain scopes. https://developers.google.com/workspace/classroom/guides/auth
- Exact scopes for studentSubmissions.patch, for listing courses, and for looking up the student's own submission: not captured.
- Whether modifyAttachments works after turnIn, and whether reclaim returns ownership: not researched.
- Whether the Classroom API is usable on Education Fundamentals: no edition restriction seen on the API pages; not confirmed as licensing fact.

Drive and storage:

- Suggested student cap of about 3 GB: not on https://support.google.com/a/answer/10403871 . The page does say over-limit users "can't upload new files or images to Google Drive" and "can't create files in collaborative content creation apps", applying once the organisation exceeds pooled storage by 25 percent or for 14 days.
- Hard-stop behaviour framed as a tenant-wide event: https://support.google.com/a/answer/12033430 describes admin-set per-user limits ("They can't upload new files", "nobody can edit or copy their affected files"), not pooled exhaustion.
- Shared-drive content bypasses a student's personal quota: not supported; the FAQ says shared drives count toward pooled storage and gives no exception at the over-limit point. https://support.google.com/a/answer/9214707 . Do not design around this.
- Ownership cannot cross domains: thread unreadable. https://support.google.com/a/thread/145967223
- Docs API create then insertText produces a single-paste version history: the page fetched covers insertText only. https://developers.google.com/workspace/docs/api/how-tos/move-text
- Editor revisions "get merged": not on https://developers.google.com/workspace/drive/api/reference/rest/v3/revisions/list (the incomplete-list and UI-more-complete warnings are).
- Whether Drive appProperties survive the ownership transfer at turnIn: not researched; test.
- Per-call quota unit cost of a Drive upload: not captured; test before relying on the checkpoint idea in 5.6(c).
- Whether the app's drive.file grant lets the teacher's Weft app read the file after ownership transfer: not addressed by any fetched page; the single most important experiment.

Admin and legal:

- "Don't allow users to access any third-party apps" is the default posture: the page marks "Allow users to access any third-party apps" as the default. https://support.google.com/a/answer/7281227
- Domain-wide delegation "will slow or kill the review": Unit 42 documents the attack surface, not reviewer behaviour. https://unit42.paloaltonetworks.com/critical-risk-in-google-workspace-delegation-feature/
- Whether a delegated service account impersonating the student satisfies turnIn's owner check: untested.
- SDPC NDPA v2.2 as "the standard instrument" and the fastest route through review: the page confirms v2.2 and "more than 222,000 signed agreements across 13,000+ school districts and 35 State Alliances" only. https://privacy.a4l.org/national-dpa/
- SDPC Resource Registry counts: the page renders no figures. https://sdpc.a4l.org/
- NYSED Parents' Bill of Rights commercial-use clause: certificate error on fetch. https://www.nysed.gov/sites/default/files/programs/data-privacy-security/parents-bill-of-rights_2.pdf
- Illinois SOPPA specifics (written DPA before transfer, deletion, breach notice, public posting): landing page only. https://www.cps.edu/about/policies/student-online-personal-protection-act/
- FERPA "direct control" analysis: the CDT page supports the test but not the storage-location inference; the FPF page treats "direct control" as defined. https://cdt.org/insights/commercial-companies-and-ferpas-school-official-exception-a-survey-of-privacy-policies/ and https://fpf.org/blog/who-exactly-is-a-school-official-anyway/
- Education editions FAQ originality-report and practice-set gating: not on the page. https://support.google.com/a/answer/7676757
- Education Privacy Notice "disclaims" protections outside Core Services: the notice scopes rather than disclaims. https://workspace.google.com/terms/education_privacy/
- Refresh-token storage on a student Mac under a district security review: no Google guidance found.
- Google's OAuth verification and CASA assessment costs in dollars: not sourced from Google; third-party figures deliberately not used.

Precedents (pages blocked or partial):

- Turnitin Classroom add-on (Education Plus, submit through the Turnitin attachment, draft-grade passback): 403. https://guides.turnitin.com/hc/en-us/articles/45224509873549-Google-Classroom-FAQ-for-Turnitin-Feedback-Studio and https://guides.turnitin.com/hc/en-us/articles/45224551462797-Working-with-grades-in-Google-Classroom
- Hapara Workspace and Drive folders: 403. https://support.hapara.com/hc/en-us/articles/4406519621389-H%C4%81para-Workspace-and-Google-Drive
- Brisk Inspect Writing as a draft trail "without the vendor holding the essay": the page says nothing about storage. https://www.briskteaching.com/inspect-writing
- Edpuzzle roster re-import behaviour: 403. https://support.edpuzzle.com/hc/en-us/articles/360045277072-Importing-new-students-from-Google-Classroom
- GoGuardian privacy commitments: the docs page is an enablement step only. https://docs.goguardian.com/products/org-management/enable-in-google-admin-console
- Locked mode "rooted in ChromeOS verified boot, cannot be ported": the page says locked mode uses ChromeOS secure boot and needs a managed Chromebook, nothing about porting. https://www.chrmbook.com/locked-quiz/
- Exam.net "after the exam" Classroom export article: JavaScript shell, unreadable. https://support.exam.net/s/article/after-the-exam-export-and-handle-the-exam-in-google-classroom

## 8. Sources used in the reasoning

DigiExam and category:
- https://www.digiexam.com/platform/integrations
- https://www.digiexam.com/integrations
- https://support.digiexam.se/api/v2/help_center/en-us/articles.json
- https://support.digiexam.se/hc/en-us/articles/8476726498076-Print-Download-student-exam-papers-as-PDF
- https://workspace.google.com/marketplace/search/digiexam
- https://www.eduappcenter.com/apps/626
- https://softwarefinder.com/lms/digiexam
- https://exam.net/streamline-exam-workflow-with-lms-integration
- https://support.google.com/edu/assignments/answer/9069054
- https://support.google.com/edu/assignments/answer/9433485
- https://www.instructure.com/resources/blog/collaboration-theme-new-canvas-integrations-google-google-assignments-lti-13-update
- https://ed.link/community/does-google-support-lti-1-3-lti-advantage/
- https://support.google.com/docs/answer/7634943
- https://www.briskteaching.com/use-cases/google-teachers
- https://support.google.com/edu/classroom/answer/9424252
- https://www.kamiapp.com/privacy-policy/
- https://www.eff.org/deeplinks/2023/10/how-goguardian-invades-student-privacy
- https://classsizematters.org/wp-content/uploads/2025/10/model-PBOR-rev.-10.21.25.pdf

Classroom and Drive APIs:
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork/create
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/modifyAttachments
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/turnIn
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions/patch
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.courseWork.studentSubmissions
- https://developers.google.com/workspace/classroom/reference/rest/v1/courses.students/list
- https://developers.google.com/workspace/classroom/limits
- https://developers.google.com/workspace/classroom/reference/limits
- https://developers.google.com/workspace/drive/api/guides/limits
- https://developers.google.com/workspace/docs/api/limits
- https://developers.google.com/workspace/drive/api/guides/manage-revisions
- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/workspace/classroom/guides/auth
- https://developers.google.com/workspace/classroom/guides/key-concepts/domain-wide-delegation
- https://workspaceupdates.googleblog.com/2021/04/changes-to-google-workspace-storage.html
- https://support.google.com/docs/answer/6388102
- https://www.eastcentral.edu/free/ai-faculty-resources/using-google-docs-to-detect-ai/

Add-ons, verification, admin and terms:
- https://developers.google.com/workspace/classroom/add-ons
- https://developers.google.com/workspace/classroom/add-ons/get-started/addons-lti-comparison
- https://developers.google.com/workspace/classroom/add-ons/developer-guides/attachment-interactions
- https://developers.google.com/workspace/classroom/add-ons/developer-guides/review-process-overview
- https://support.google.com/edu/classroom/answer/12234529
- https://support.google.com/edu/classroom/answer/12351654
- https://support.google.com/cloud/answer/13464321
- https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- https://support.google.com/cloud/answer/15549945
- https://discuss.google.dev/t/google-education-approval-delay-waiting-for-3-months/260303
- https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data
- https://knowledge.workspace.google.com/admin/getting-started/editions/manage-access-to-unconfigured-third-party-apps-for-users-designated-as-under-18
- https://knowledge.workspace.google.com/admin/apps/control-api-access-with-domain-wide-delegation
- https://workspaceupdates.googleblog.com/2024/12/configure-third-party-apps-by-select-api-scopes-general-availability.html
- https://developers.google.com/workspace/classroom/best-practices/access-control-enhancements
- https://support.google.com/edu/classroom/answer/11081157
- https://workspace.google.com/terms/education_terms/
- https://www.google.com/appsstatus/dashboard/incidents/KjFLjecwg9xeewnUYjh1
- https://www.google.com/appsstatus/dashboard/incidents/GDxbSoojBb9yyEhU2Cua
