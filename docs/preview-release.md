# Preparing the public preview

The current public preview destination is
[jasl/cybros.ai](https://github.com/jasl/cybros.ai). It is already public; its name
may change before release. Confirm the destination again before publishing and
update repository and installation links together if it changes.

The existing repository remains the development workspace until the remaining
work and release checks are complete. Prepare a reviewed source snapshot with a
fresh local history, then publish it to the selected public repository. Keep the
development checkout's remote and history in place.

## Establish the release candidate

Use real installations while finishing the remaining backlog. Record the source
revision or image tag, environment, reproduction steps, expected result and
observed result for each issue. Avoid including provider credentials or personal
conversation contents in shared reports.

Review deferred entries against the current implementation before declaring the
backlog complete. Separate unfinished implementation, missing verification,
conditional follow-ups and accepted limitations. Each actual work item needs
implementation and relevant evidence; each accepted limitation needs a clear
statement in the owning manual. Standing design constraints remain constraints.
Removing entries alone does not establish completion, and an old measurement
does not qualify a changed implementation.

The release candidate should cover these journeys on the distribution being
published:

- Install from scratch, create the first account, configure a provider and pair rho.
- Complete a real conversation with a tool result; answer a question and approval.
- Reopen history, stop work, and recover after restarting the daemon and services.
- Exercise the selected delivery surfaces, including Telegram and scheduled jobs
  if they are included in the preview's supported use cases.
- Back up and restore a disposable installation, including uploaded files and
  encrypted credentials; verify any supported upgrade path separately.

Record automated and manual results separately. Use the
[local verification instructions](../e2e/README.md) and component checks for the
candidate revision. GitHub smoke covers a smaller set than full local acceptance.
Use the [evaluation runbook](evals-runbook.md) for model-quality measurements;
publish the corpus, model, configuration, aggregate measurements and limitations
with the conclusion. Retain supporting raw evidence privately, outside the
tracked source tree.

## Finish the public manuals

Keep the [manual index](README.md) and [first-use guide](getting-started.md)
accurate for the candidate's commands and interfaces. Verify installation URLs,
image tags, prerequisites, known limitations, data ownership and recovery steps.
Do not advertise a URL or release tag before its files are available.

When the public snapshot is ready, update source-location metadata with it:

- Installer clone instructions in `install/src/`, their rendered `install.sh`
  and matching shell-test expectations.
- Gem homepage fields and the ACP registry's repository and license links.
- Container source and revision labels together, using the repository and commit
  actually used to build each image. A development commit paired with the public
  URL would name source the public repository cannot supply.

Until then, keep development-build provenance accurate. The public repository's
existence alone does not make installer files or commit-specific URLs available.

Retiring old planning and archive directories is a separate future change.
Before removing them, move still-active requirements and maintenance instructions
into their owning current documents, reconcile unresolved work and replace
remaining references in repository instructions, tests, scripts and manuals.
Preserve private evaluation evidence needed to substantiate published claims. Then
check links and run the applicable verification from the resulting tree.

## Review the contents that will become public

A new root commit removes ancestry from the new repository. It does not remove
private information that is still present in the files being copied. Review the
exact exported tree, including tracked files that `.gitignore` now ignores.

Include source comments, fixtures, examples, logs, evaluation records, screenshots,
documents and generated assets in that review. Check for private hostnames and
addresses, personal paths, emails, credentials, conversation content and embedded
document or image metadata. Distinguish intended public author attribution and
license notices from information that should be removed; preserve required
licenses and third-party notices.

Remove generated real-model runs and intermediate analysis from tracked source;
adding an ignore rule does not untrack an existing file. Retain authored regression
fixtures and the samples required for specific model adaptations or protocols.
Publish reviewed evaluation conclusions, not raw transcripts or generated scripts.

Inspect build inputs and artifacts separately. A container layer, package receipt,
source URL or build label can retain information absent from the final source
tree. A Git snapshot also does not migrate or sanitize issues, pull requests,
releases, CI artifacts, package registries or installed application data.

Use automated searches to find candidates and review their context. Neither a
clean search result nor a one-commit repository proves the absence of private
information. If a credential was exposed to someone who should not have it,
replace it; removing its text does not invalidate it.

## Prepare the public snapshot when ready

First commit and review the intended source state in the development repository.
Keep the private record of its exact revision and validation results. Export that
revision into a new, empty directory; do not copy the old `.git` directory, refs,
bundles or a mirror. The example below prepares local source only:

```sh
# Replace these three values with the reviewed source and a new destination.
development_repo=/absolute/path/to/development-repository
release_revision=FULL_REVIEWED_COMMIT_ID
preview_dir=/absolute/path/to/new-preview-repository

(
  set -eu
  mkdir "$preview_dir"
  git -C "$development_repo" archive --format=tar \
    --output="$preview_dir/source.tar" "$release_revision"
  tar -xf "$preview_dir/source.tar" -C "$preview_dir"
  rm "$preview_dir/source.tar"
)
```

`git archive` exports committed tracked content; local modifications and untracked
files are absent. Check for submodules, Git LFS objects and export attributes if
they are introduced, since they need their own export review. Compare the export
with the intended candidate and complete the content review before continuing.

Initialize the destination with the public identity you intend to disclose:

```sh
git -C "$preview_dir" init -b main
git -C "$preview_dir" config user.name "Your public author name"
git -C "$preview_dir" config user.email "Your public author email"
git -C "$preview_dir" add --force --all
git -C "$preview_dir" diff --cached --stat
# Review the staged contents before creating this commit.
git -C "$preview_dir" commit -m "chore: prepare public preview"
git -C "$preview_dir" log --all --format=fuller
git -C "$preview_dir" rev-list --all --count
```

The count should be one, and both author and committer metadata must be suitable
for publication. `--force --all` preserves the reviewed export even when an
existing tracked file matches an ignore rule; use it only in this clean export.
Check the staged inventory against the reviewed export. Verify builds and installation from a fresh
checkout of this new repository before release; avoid relying on ignored files
or credentials from the development checkout.

After validation, connect the fresh local repository to the chosen destination:

```sh
git -C "$preview_dir" remote add origin https://github.com/jasl/cybros.ai.git
git -C "$preview_dir" remote -v
```

Check that this is still the intended public repository and that its remote
branches and tags are in the expected state. Publish only the reviewed branch
and explicitly chosen tags; do not mirror or push development refs. Keep the original
repository and its history available for development without transferring them
to the public destination. Future updates should be reviewed changes against the
public tree; merging an old-history branch would reconnect the ancestry that this
procedure intentionally leaves behind.

If push protection rejects the initial snapshot, remove the affected content and
replace that unpublished root commit before trying again. Adding a later deletion
commit still sends the original content in its ancestry. Review all affected
credentials and replace any real exposed tokens; bypassing the warning does not
clean the snapshot. See [GitHub's blocked-push instructions](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/work-with-leak-prevention/push-protection-on-the-command-line).

## Publish the supported scope

The preview announcement should name the supported platforms, installation path,
tested source and image versions, known limitations and feedback channel. State
data-migration requirements and distinguish tests, real-use observations and
benchmarks. Publish only the artifacts that passed the source and artifact review.
Repository migration, historical-document retirement and a public release are
separate actions, each with its own reviewable result.
