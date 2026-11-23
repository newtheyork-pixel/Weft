-- Carry forward the previous draft (Linear SAT-5). Re-runnable.
--
-- 1. tests.carry_forward: per-assignment teacher switch. When on, a student
--    beginning draft N with no work yet starts from their own previous draft
--    (only if the teacher has RETURNED it; a sealed essay can't open for the
--    student before that). Default false keeps every existing row, draft 1,
--    and the Electron editor (which never sends the column) unchanged. The
--    Mac app sends true when it creates a draft with New draft. Teachers
--    write it through the existing "teacher updates own tests" /
--    "teacher inserts own tests" policies; no policy change is needed.
--
-- 2. list_my_earlier_drafts(p_test_id): the caller's own SUBMITTED essays in
--    the same version group as p_test_id, from drafts numbered below it.
--    Metadata only (no essay body, no cipher, no wrap): submission id,
--    version number, submitted_at, released_at. Students can't read sessions
--    or closed sessions' tests, so they can't map their essay_submissions
--    rows to a draft number themselves. SECURITY DEFINER and keyed on
--    auth.uid()'s own students rows, so it can return nobody else's work.
--    The client then reads the sealed body from its own essay_submissions
--    row (existing RLS) and the student wrap from its released essay_grades
--    row (existing RLS), exactly like Returned work.

alter table public.tests
  add column if not exists carry_forward boolean not null default false;

create or replace function public.list_my_earlier_drafts(p_test_id uuid)
returns table(submission_id uuid, version_number integer,
              submitted_at timestamptz, released_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cur as (
    select coalesce(t.version_group_id, t.id) as gid,
           coalesce(t.version_number, 1)      as vn
    from tests t
    where t.id = p_test_id
  )
  select es.id                          as submission_id,
         coalesce(t.version_number, 1)  as version_number,
         es.submitted_at,
         g.released_at
  from cur
  join tests t             on coalesce(t.version_group_id, t.id) = cur.gid
                          and coalesce(t.version_number, 1) < cur.vn
  join sessions s          on s.test_id = t.id
  join students st         on st.session_id = s.id and st.user_id = auth.uid()
  join essay_submissions es on es.session_id = s.id and es.student_id = st.id
  left join essay_grades g on g.submission_id = es.id
  where auth.uid() is not null
    and es.submitted_at is not null
  order by coalesce(t.version_number, 1) desc, es.submitted_at desc;
$function$;

revoke all on function public.list_my_earlier_drafts(uuid) from public, anon;
grant execute on function public.list_my_earlier_drafts(uuid) to authenticated;
