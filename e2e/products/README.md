# Product E2E

Run `bundle install` and `bundle exec rake` here. This bundle owns real rho and
rho-env integration, UI, filesystem effects, processes and checkpoint restoration.
Its environment host fixture embeds the real library on an independent executor
address; it is test support, not a standalone rho deployment.

`bundle exec rake smoke_harness_test smoke rubocop` is the bounded CI gate.
`rake realtime` and paid diagnostics remain explicit opt-ins. `N=` accepts a
Minitest test name or slash-delimited regular expression.

See the root [E2E guide](../README.md) for diagnostic tasks and isolation.
