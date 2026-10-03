# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  group "Checks", parallel: 2 do
    step "Repo hygiene", "ruby ../bin/lint-eof"
    step "Style: Ruby", "bin/rubocop"
    step "Architecture", "bundle exec archspec check"
    step "Zeitwerk", "bin/rails zeitwerk:check"
    step "Solid Queue configuration", "env RAILS_ENV=test bin/jobs check"
    step "Style: JavaScript", "bun run lint:js"
    step "Tests: JavaScript", "bun run test:js"

    step "Security: Gem audit", "bin/bundler-audit"
    step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

    group "Tests" do
      step "Tests: Rails", "bin/rails test"
      step "Tests: Manual tooling", "bin/rails test ../e2e/manual"
      step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
      step "Tests: System", "bin/rails test:system"
    end
  end

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
