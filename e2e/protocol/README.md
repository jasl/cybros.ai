# Protocol E2E

Run `bundle install` and `bundle exec rake` here. This bundle owns SDK and Nexus
contracts and deterministic fake executors; it has no rho or rho-env dependency.
The fake peer implements only the behavior needed by its protocol tests. It is
not a deployable executor runtime.

`bundle exec rake smoke_harness_test smoke rubocop` is the bounded CI gate.
`bundle exec rake 'e2e_group[13]'` runs the fake-peer contract loop. `N=` accepts a
Minitest test name or slash-delimited regular expression.

The root [E2E guide](../README.md) describes world isolation and diagnostics.
