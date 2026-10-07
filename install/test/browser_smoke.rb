require "open3"
require "rho/browser"

# Use the shipped browser owner and driver, including its normal child environment.
output, status = Open3.capture2e(Rho::Runner::ChildEnv.call, "python3", "-c",
                               "import sys, docx, openpyxl, pptx, pypdf; assert sys.prefix == '/opt/cowork'; print('cowork imports ready')")
abort output unless status.success?

driver = Rho::Browser::Driver.new
begin
  driver.start
  page = driver.new_page
  page.set_content(<<~HTML)
    <!doctype html><html lang="en"><meta charset="utf-8"><title>rho browser smoke</title>
    <style>body { font: 24px sans-serif; margin: 48px; } button { font: inherit; padding: 16px; }</style>
    <h1>Browser QA</h1><p>中文浏览器检查</p>
    <button onclick="document.querySelector('output').textContent='Ready'">Generate</button>
    <output>Waiting</output></html>
  HTML
  page.locator("button").click
  abort "browser interaction failed" unless page.locator("output").inner_text == "Ready"
  page.screenshot(path: File.join(ARGV.fetch(0), "browser.png"), fullPage: true)
  puts "rho-browser rendered a page, clicked a control and saved a screenshot"
ensure
  driver.stop
end
