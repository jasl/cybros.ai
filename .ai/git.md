# Git Workflow Rules

**Applies to:** every project.

- Branches: descriptive names, classified naturally — a type prefix (`feat/`, `fix/`, `refactor/`,
  `chore/`) is the usual shape, not a mandate; lowercase letters, numbers, hyphens, underscores,
  and slashes only.
- Commits: one coherent concern with a clean rollback profile. Isolate schema/migration changes
  when independently reviewable; keep doc-only changes separate; tests travel with the
  implementation they protect. Conventional-commit subject (`type: description`), imperative, no
  final period, no emojis; add a body explaining why when the change spans files or the reason is
  not obvious.
- Dirty worktrees: inspect staged, unstaged, and untracked changes before committing; preserve
  unrelated work via path-limited staging or `git commit --only`; never revert changes you did not
  make unless explicitly asked.
- Integration: prefer rebase over merge commits for parallel work. After rebasing, reassess the
  affected paths and interactions and rerun checks whose evidence the rebase invalidated, using
  `.ai/ci.md`'s scope rules. A rebase or commit does not automatically require full suites or E2E.
