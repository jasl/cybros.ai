module BrowserTest
  # A PAGE THAT REMEMBERS WHAT WAS DONE TO IT, and nothing else. The tools
  # talk to a page through a handful of methods; this answers them all so
  # the whole extension runs under test with no driver, no Node, no
  # Chromium. Its refs are whatever `[ref=eN]` its tree mentions, so a ref
  # from an older page queries as nil, as the aria-ref engine does.
  class FakePage
    attr_reader :calls, :url, :closed
    attr_accessor :stale_after_query
    attr_writer :opener

    def initialize(url: "about:blank", title: "Blank", tree: "- document [ref=e1]")
      @url = url
      @title = title
      @tree = tree
      @calls = []
      @closed = false
    end

    def title = @title
    def closed? = @closed
    def opener
      @opener unless @opener&.closed?
    end
    def close! = @closed = true

    def close
      @calls << [:close]
      @closed = true
    end
    def refs = @tree.scan(/\[ref=(\w+)\]/).flatten

    def goto(url)
      @calls << [:goto, url]
      @url = url
    end

    def aria_snapshot(mode:)
      @calls << [:aria_snapshot, mode]
      @tree
    end

    def locator(selector)
      @calls << [:locator, selector]
      FakeLocator.new(self, selector)
    end

    def query_selector(selector)
      @calls << [:query_selector, selector]
      FakeElementHandle.new(self, selector) if refs.include?(selector.delete_prefix("aria-ref="))
    end

    def screenshot(path:, fullPage:)
      @calls << [:screenshot, path, fullPage]
      File.write(path, "PNG")
    end

    def evaluate(expression)
      @calls << [:evaluate, expression]
      { "echo" => expression }
    end
  end

  FakeElementHandle = Data.define(:page, :selector) do
    def dispose = page.calls << [:dispose, selector]
  end

  FakeLocator = Struct.new(:page, :selector) do
    # playwright-ruby-client 1.62.0 counts via evaluation in the main
    # world, where the utility world's snapshot refs are unavailable.
    def count = 0

    def click(timeout: nil)
      page.calls << [:click, selector, timeout]
      raise page.stale_after_query if page.stale_after_query
    end
    def fill(text, timeout: nil) = page.calls << [:fill, selector, text, timeout]
    def press(key, timeout: nil) = page.calls << [:press, selector, key, timeout]
  end

  # A driver that counts starts and stops, can be told to fail, and can be
  # told to HANG in either — the session's clocks are what that exercises.
  class FakeDriver
    attr_reader :starts, :stops, :page, :pages

    # `page:` is the page the FIRST tab gets, so a test can shape it;
    # every later tab gets a fresh one.
    def initialize(page: FakePage.new, fail_starts: 0, hang_start: false, hang_stop: false)
      @page = page
      @injected = page
      @pages = []
      @fail_starts = fail_starts
      @hang_start = hang_start
      @hang_stop = hang_stop
      @starts = 0
      @stops = 0
    end

    # `started?` is LIVENESS OF A HANDLE, as the real driver's is: a start
    # that raised left nothing behind, and a stop cleared it.
    def started? = @live == true
    def alive? = started? && !@dead
    def die! = @dead = true
    def open_pages = started? ? @pages.reject(&:closed?) : []

    # `started?` flips at the START of start, as the real driver's does
    # (it holds the transport from the first step), so a stop that races a
    # start is a real stop; a start that fails clears it, as the real one
    # does.
    def start
      @live = true
      @starts += 1
      sleep if @hang_start
      if @starts <= @fail_starts
        @live = false
        raise "driver unavailable"
      end

      @dead = false
      self
    end

    def new_page
      page = @injected || BrowserTest::FakePage.new
      @injected = nil
      @pages << page
      page
    end

    # A no-op when nothing is running, as the real driver's is — a stop
    # that counted would make every idempotent close look like a leak.
    def stop
      return unless started?

      @live = false
      @stops += 1
      @pages.each(&:close!)
      sleep if @hang_stop
    end
  end
end
