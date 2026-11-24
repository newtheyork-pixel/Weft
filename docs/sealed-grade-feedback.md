# Sealed grade feedback (SAT-13)

The overall comment on a grade (`essay_grades.feedback`) is sealed on the
grading Mac. The score is not sealed: `points`, `points_possible` and
`released_at` stay numeric/plain columns behind the existing grade
permissions, because the Blackbaud writeback function
(`supabase/functions/blackbaud-write-grade`) reads them and sends a number.

Margin comments (`essay_comments.body`) are a separate field and are **not**
covered here.

## Format

- `feedback_cipher`: a normal Weft envelope (`P256-HKDF-SHA256-AES256GCM`)
  with its own random content key, not the essay's. Content AAD is
  `grade-feedback|<submission id, lowercased>|v1`, so a ciphertext moved to
  another submission fails to open.
- Wraps go to every staff key returned by `get_grade_feedback_staff_keys`
  (the grading teacher and eligible school admins, SAT-20). Sealing refuses
  any key that is not a genuine `password` key, and refuses to seal unless
  this Mac's own key is among them.
- `feedback_student_wrap`: written in the same request that returns the
  grade. The content key is AES-GCM sealed under a 32-byte per-submission key
  from `get_grade_feedback_return_keys`. The AAD is
  `grade-feedback-return|<submission id>|v1`.
- The write clears the legacy `feedback` column to `""` in the same write
  that stores the ciphertext.

## Who can read it

| Reader | How |
| --- | --- |
| Grading teacher, school admins | Their essay-password key opens their wrap. |
| Student, after return | Signed in with Google, the student gets the per-submission return key and opens `feedback_student_wrap`, in Weft or the web portal. The browser only sees the feedback ciphertext and that key, never the essay. |
| Database backup alone | Nothing. The return key is derived from a server secret that is not in the database. |
| Operator with the database **and** the server secret | Returned feedback, the same as returned essays under SAT-24. Draft feedback (not yet returned) has no student wrap and stays closed to them. |

## Behaviour in the Mac app

- A staff member whose key cannot open the feedback sees the comment as
  locked. They can still change the score, which keeps the sealed feedback
  as it is. They cannot edit it or return it for the first time.
- If sealing fails (no key on this Mac, student key unavailable), nothing is
  written and the typed comment stays pending in the grading screen.
- Writes are conditional on the `updated_at` the grader loaded, so a stale
  draft cannot overwrite a grade that someone else changed or returned.
  The screen sends one write per student at a time and queues the next one.

## Rollout

1. Count existing non-empty plaintext feedback
   (`select count(*) from essay_grades where coalesce(feedback,'') <> ''`).
2. Apply the Tessera migration `20261123000005_sealed_grade_feedback.sql`
   together with the portal update. Ship the Mac release at the same time:
   the old Mac app writes plaintext and does not send `updated_at`.
3. Existing plaintext stays readable until an authorized grader re-saves the
   grade in the updated Mac app, which replaces it with sealed feedback in a
   single write. Verify that the teacher and the student can both open it
   before you clear any remaining plaintext.
4. Older database backups can still hold plaintext feedback.

## Checks before closing SAT-13

- A score-only grade saves and returns. Blackbaud posts the same score.
- A teacher and a school admin can edit the sealed feedback.
- A student opens only their own returned feedback, in Weft and in the portal.
- With the essay key missing, the edit stays pending and nothing is lost.
