# rho-browser

An optional rho extension providing `browser_snapshot`, `browser_navigate`,
`browser_click`, `browser_type`, `browser_screenshot`, and `browser_evaluate`
through Playwright. Load `rho/browser` through rho's extension settings.
The Node Playwright driver and Chromium must be installed separately. Enabling
the plugin or starting an enabled plugin launches and immediately closes a test
browser before making its tools available. If that check fails, the plugin stays
inactive and Settings shows installation guidance. Repair the driver command or
install Playwright and Chromium, then enable the plugin again. Core settings and
other plugins remain available. Ordinary browsing sessions still start on first use.

The process shares one browser context, including cookies. Each agent loop
gets its own tab: calls within a loop serialize, and different loops can
browse concurrently. Changing a runner's working directory keeps the session.
The integration requires a daemon restart to be replaced or removed: stop rho,
change the extension selection, then start it again. A live replacement is
refused before changing the shared browser context.

`plugins["rho.browser"].configuration.idle_seconds` in `<RHO_HOME>/settings.json` sets the idle window for both individual tabs and
the whole browser (default: 600 seconds). An unused tab can close while other
loops keep browsing. A call in progress is protected, and its idle window
starts when the call finishes. When the whole browser is idle it is stopped,
releasing its shared context too. Shutdown closes the session.

Popups created by a tab are closed with it, including nested popups. Pages
left without an owner when their opener closes itself are reclaimed by the
same idle reaper; another loop's tab and its popups remain available.

Idle cleanup does not mean an agent loop has ended. A loop returning later
gets a new tab. The first result from every new tab carries a notice that
earlier tab refs are invalid, including the first use of the browser. Further
calls on that tab omit the notice; cancellation preserves it for the next
result. Navigate again as needed and use the current page's snapshot refs.

Set the plugin field `playwright_cli` to select the installed Node driver when
`playwright` on `PATH` does not match the gem's supported Playwright minor.

Run the package checks with `bundle exec rake` and build with
`bundle exec rake build`. The default checks require no browser installation
or network access.

Configure the plugin through **Settings → Plugins → Browser** or
`rho extensions configure rho.browser` with a field-operation batch. Browser
sessions are process-wide, so replacing or disabling an active browser plugin
requires a rho restart. Driver discovery can still use the deployment variable
`RHO_BROWSER_PLAYWRIGHT_CLI`, the installation prefix, or `playwright` on PATH.
