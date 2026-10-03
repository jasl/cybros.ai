---
name: deploy-notes
description: How this project is deployed. Use before any deploy or release step.
---
# Deploy notes

This project deploys from `main` only.

1. Run `bin/rails test` and wait for green.
2. Tag the release `vYYYY.MM.DD`.
3. Push the tag; the deploy follows the tag, never a branch.
