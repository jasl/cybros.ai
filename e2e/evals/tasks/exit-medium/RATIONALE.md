# exit-medium

**Measures.** A medium coding task measured by its verification result: a multi-file
FEATURE against shipped, red tests in a project the model has never seen
— grep, read, plan, edit several files, run, iterate. The shipped tests
are the specification and are RESTORED before the verdict (rails/ai-evals'
rule), so an edited test buys nothing; the model must also add one test
of its own (`added_tests >= 1`).

**Converts.** `e2e/test/live_exit_medium_test.rb:389-432` (the task, the
project `:52-381`, the five checks). The live lane reads this task's
`environment/` as its project (one fixture source).

**Dimensions.** reach = explored AND ran the suite; success = ≥ 2 lib/
files edited, a run after the last edit, every round completed, no
attention, the loop completed; conduct = `did_not_edit_shipped_tests`;
task pass = the suite green after the restore AND `added_tests >= 1`;
`lib_files_edited` is a fact.

## Reading a red

- **lane bug** — `error`, or the deadline (1500 s) before a round settled.
- **model conduct** — "fewer than two lib/ files edited" (one file, the
  suite still red); `task_pass: false` with "added tests: 0" (it
  implemented and did not test); `conduct.did_not_edit_shipped_tests:
  false`.
- **kernel finding** — "a round did not complete: {…}" with a kernel
  error key; "the feed called for a person" on a lane that scripts none;
  `task_pass: true` beside a red predicate (a one-file feature that
  passed: read the diff in the artifact before believing the shape).
