# rho-browser

An optional rho extension providing `browser_snapshot`, `browser_navigate`,
`browser_click`, `browser_type`, `browser_screenshot`, and `browser_evaluate`
through Playwright. Load `rho/browser` through rho's extension settings.
The Node Playwright driver and Chromium must be installed separately; loading
the extension does not start a browser.

The process shares one browser context, including cookies. Each agent loop
gets its own tab: calls within a loop serialize, and different loops can
browse concurrently. Changing a runner's working directory keeps the session.

`RHO_BROWSER_IDLE_SECONDS` sets the idle window for both individual tabs and
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

Set `RHO_BROWSER_PLAYWRIGHT_CLI` to select the installed Node driver when
`playwright` on `PATH` does not match the gem's supported Playwright minor.

Run the package checks with `bundle exec rake` and build with
`bundle exec rake build`. The default checks require no browser installation
or network access.
