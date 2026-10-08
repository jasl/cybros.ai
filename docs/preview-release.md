# Rolling release workflow

The public source repository is [jasl/cybros.ai](https://github.com/jasl/cybros.ai).
Its `main` branch receives reviewed snapshots from the development repository.
The Docker stack installs the published `latest` images. There is no numbered
product release or required Git release tag, and installation instructions do
not pin a source commit.

Implement and verify fixes in the development repository, then synchronize the
intended changes into the public checkout. Keep the development repository's
history and private working material separate from the public repository.

## Verify the changes being synchronized

Run the relevant local component checks and cross-project journeys for the
changed behavior. GitHub Actions runs smoke and key quality checks; a green CI
run does not replace full local acceptance where that is required. Use the
[local verification instructions](../e2e/README.md) and owning package guides.

For installation or setup changes, exercise a fresh installation, account and
provider setup, device pairing, and a first conversation. For changes affecting
persistent data, verify the supported upgrade or restore path on a disposable
installation. Test Telegram, scheduling and other delivery surfaces when the
change affects them.

Record automated and manual results separately. Keep the source revision and
logs with the verification evidence so a failure can be reproduced; this record
is diagnostic information, not a version or commit that users must install.
When CI fails only in the public repository, compare the failing files,
dependencies and logs with the development run before deciding whether the
failure is intermittent or caused by the exported tree. Fix the owning source
or test in the development repository and synchronize that fix.

## Keep the public tree usable

The public snapshot omits internal plans and archived development documents.
Retain the source, package metadata, licenses, installation files, tests, current
manuals and other inputs needed to build, install and verify the published tree.
Keep active requirements in their owning current manuals rather than depending
on a document omitted from the snapshot.

Check the exported files and links after applying the exclusions. In particular:

- The [first-use guide](getting-started.md) and [stack guide](../install/stack/README.md)
  must describe the commands and defaults that are actually available.
- Installer clone instructions, package homepages, ACP registry links and image
  source labels use the public repository. Source and installer links follow `main`.
- Tests and build steps must not require an omitted plan, ignored local artifact,
  private checkout or provider credential.
- Preserve licenses and third-party notices. Keep credentials, personal data and
  generated real-model runs out of the public tree; retain needed diagnostic
  evidence privately and publish reviewed conclusions with their limitations.

Verify the resulting public checkout as well as the development tree. Removing
internal documents does not by itself prove that all remaining links and build
inputs are complete.

## Synchronize source and publish images

Apply the reviewed files to the existing public checkout and inspect its diff.
Commit the intended update on `main` and push that branch after verification.
Do not copy the development `.git` directory, merge its history into the public
repository, or recreate the public repository for each update. Source
synchronization is a manual maintainer step.

Image publishing is an explicit maintainer command, described in the
[image guide](../install/docker/README.md#publish-the-current-checkout). It freezes
a clean, committed checkout and builds Nexus, rho and the updater on native amd64
and arm64 Docker Engines. All six runtime checks finish before upload; all three
release indexes and their image labels are verified before promotion to `latest`,
which is verified again. UTC minute tags cannot be reused. These tags require no
product version number or Git release tag; each image's OCI revision identifies
the source commit used for its build.

Keep the public source and installed image behavior aligned. If a snapshot or
image has not completed its intended checks, say which verification is missing
rather than presenting an older green run as evidence for the new files.

## Explain upgrades and known limits

The public manuals should state supported platforms, prerequisites, known
limitations, configuration ownership and recovery steps. Interfaces and database
schemas can still change incompatibly. Describe any required data migration or
fresh-database setup alongside the change.

Host installations update their existing checkout with `rho update`; Docker
installations pull the rolling images with `./cybros update`. Back up first and
follow the [stack upgrade and restore guidance](../install/stack/README.md#status-logs-and-upgrades).
An older executable or image does not reverse a database migration.
