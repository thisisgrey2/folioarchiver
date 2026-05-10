#!/usr/bin/env python3
"""
Folio Scraper — standard macOS window app.
Paste portfolio URLs, queue them, and save images to ~/Desktop/<studio>/.
"""

import queue
import subprocess
import sys
import threading
from collections import deque
from pathlib import Path

import objc
from AppKit import (
    NSApp,
    NSAlert,
    NSApplication,
    NSApplicationActivationPolicyRegular,
    NSBackingStoreBuffered,
    NSBox,
    NSBoxSeparator,
    NSButton,
    NSColor,
    NSFont,
    NSLineBreakByTruncatingTail,
    NSLineBreakByWordWrapping,
    NSNoBorder,
    NSProgressIndicator,
    NSScrollView,
    NSTextField,
    NSView,
    NSWindow,
    NSWindowMiniaturizeButton,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskTitled,
    NSWindowZoomButton,
)
from Foundation import NSMakeRange, NSMakeRect, NSObject, NSTimer
from PyObjCTools import AppHelper

# Make sure the scraper module next to this file is importable.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from scrape import MIN_PX_DEFAULT, scrape_site


WINDOW_WIDTH = 980
WINDOW_HEIGHT = 620
SIDEBAR_WIDTH = 280
LEFT_PANEL_WIDTH = WINDOW_WIDTH - SIDEBAR_WIDTH
LOG_MAX_ENTRIES = 120


def make_label(frame, text, font_size=13, bold=False, color=None, mono=False):
    label = NSTextField.alloc().initWithFrame_(frame)
    label.setStringValue_(text)
    label.setEditable_(False)
    label.setBordered_(False)
    label.setDrawsBackground_(False)
    label.setSelectable_(False)

    if mono:
        font = NSFont.userFixedPitchFontOfSize_(font_size)
    elif bold:
        font = NSFont.boldSystemFontOfSize_(font_size)
    else:
        font = NSFont.systemFontOfSize_(font_size)

    label.setFont_(font)
    if color is not None:
        label.setTextColor_(color)
    return label


def make_wrapped_label(frame, text, font_size=13, mono=False, color=None):
    label = make_label(frame, text, font_size=font_size, mono=mono, color=color)
    label.setLineBreakMode_(NSLineBreakByWordWrapping)
    label.cell().setWraps_(True)
    label.setUsesSingleLineMode_(False)
    return label


class FolioScraperAppDelegate(NSObject):
    def init(self):
        self = objc.super(FolioScraperAppDelegate, self).init()
        if self is None:
            return None

        self._running = False
        self._job_queue = deque()
        self._current_url = None
        self._results = queue.Queue()
        self._last_output_dir = None
        self._poll_timer = None
        self._log_entries = []
        return self

    def applicationDidFinishLaunching_(self, _notification):
        self._build_window()
        self._poll_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, "pollResults:", None, True
        )
        self._refresh_queue_panel()
        self._refresh_log_panel()
        NSApp().activateIgnoringOtherApps_(True)

    def applicationShouldTerminateAfterLastWindowClosed_(self, _sender):
        return True

    def _build_window(self):
        style_mask = (
            NSWindowStyleMaskTitled
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable
        )

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT),
            style_mask,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("Folio Scraper")
        self.window.center()
        self.window.setReleasedWhenClosed_(False)
        self.window.setContentMinSize_((WINDOW_WIDTH, WINDOW_HEIGHT))
        self.window.setContentMaxSize_((WINDOW_WIDTH, WINDOW_HEIGHT))

        zoom_button = self.window.standardWindowButton_(NSWindowZoomButton)
        if zoom_button is not None:
            zoom_button.setEnabled_(False)

        mini_button = self.window.standardWindowButton_(NSWindowMiniaturizeButton)
        if mini_button is not None:
            mini_button.setEnabled_(True)

        content = self.window.contentView()

        divider = NSBox.alloc().initWithFrame_(NSMakeRect(LEFT_PANEL_WIDTH, 0, 1, WINDOW_HEIGHT))
        divider.setBoxType_(NSBoxSeparator)
        content.addSubview_(divider)

        self._build_main_panel(content)
        self._build_sidebar(content)

        self.window.makeKeyAndOrderFront_(None)

    def _build_main_panel(self, content):
        title = make_label(NSMakeRect(30, 545, 360, 34), "Folio Scraper", font_size=24, bold=True)
        content.addSubview_(title)

        subtitle = make_label(
            NSMakeRect(30, 510, 560, 26),
            "Queue artist and designer portfolio URLs and save large images into Desktop folders.",
            font_size=15,
            color=NSColor.colorWithCalibratedWhite_alpha_(0.45, 1.0),
        )
        content.addSubview_(subtitle)

        self.status_dot = make_label(
            NSMakeRect(30, 470, 16, 18),
            "●",
            font_size=14,
            color=NSColor.systemGreenColor(),
        )
        content.addSubview_(self.status_dot)

        self.status_label = make_label(
            NSMakeRect(54, 468, 540, 22),
            "Status: Ready",
            font_size=14,
            mono=True,
        )
        content.addSubview_(self.status_label)

        queue_hint = make_label(NSMakeRect(30, 420, 250, 24), "Add portfolio URL", font_size=16, bold=True)
        content.addSubview_(queue_hint)

        helper = make_label(
            NSMakeRect(30, 398, 520, 18),
            "Each click adds a site to the queue. Jobs run one after another.",
            font_size=13,
            color=NSColor.colorWithCalibratedWhite_alpha_(0.45, 1.0),
        )
        content.addSubview_(helper)

        self.url_field = NSTextField.alloc().initWithFrame_(NSMakeRect(30, 352, 430, 34))
        self.url_field.setPlaceholderString_("https://example.com")
        content.addSubview_(self.url_field)

        self.queue_button = NSButton.alloc().initWithFrame_(NSMakeRect(475, 350, 125, 38))
        self.queue_button.setTitle_("Add To Queue")
        self.queue_button.setBezelStyle_(1)
        self.queue_button.setTarget_(self)
        self.queue_button.setAction_("scrapeClicked:")
        content.addSubview_(self.queue_button)

        actions_title = make_label(NSMakeRect(30, 300, 180, 24), "Actions", font_size=16, bold=True)
        content.addSubview_(actions_title)

        self.open_desktop_button = NSButton.alloc().initWithFrame_(NSMakeRect(30, 258, 140, 32))
        self.open_desktop_button.setTitle_("Open Desktop")
        self.open_desktop_button.setTarget_(self)
        self.open_desktop_button.setAction_("openDesktopClicked:")
        content.addSubview_(self.open_desktop_button)

        self.open_last_button = NSButton.alloc().initWithFrame_(NSMakeRect(182, 258, 160, 32))
        self.open_last_button.setTitle_("Open Last Result")
        self.open_last_button.setTarget_(self)
        self.open_last_button.setAction_("openLastResultClicked:")
        self.open_last_button.setEnabled_(False)
        content.addSubview_(self.open_last_button)

        self.progress = NSProgressIndicator.alloc().initWithFrame_(NSMakeRect(360, 264, 20, 20))
        self.progress.setStyle_(0)
        self.progress.setDisplayedWhenStopped_(False)
        self.progress.setIndeterminate_(True)
        content.addSubview_(self.progress)

        current_box = NSBox.alloc().initWithFrame_(NSMakeRect(30, 90, 570, 140))
        current_box.setTitle_("Current job")
        content.addSubview_(current_box)

        self.current_job_label = make_wrapped_label(
            NSMakeRect(46, 122, 540, 84),
            "Nothing running yet.\nAdd a portfolio URL to start the queue.",
            font_size=16,
            color=NSColor.colorWithCalibratedWhite_alpha_(0.25, 1.0),
        )
        content.addSubview_(self.current_job_label)

    def _build_sidebar(self, content):
        sidebar_x = LEFT_PANEL_WIDTH + 24

        queue_title = make_label(NSMakeRect(sidebar_x, 545, 200, 28), "Queue", font_size=18, bold=True)
        content.addSubview_(queue_title)

        self.queue_summary = make_label(
            NSMakeRect(sidebar_x, 518, 220, 20),
            "No queued sites.",
            font_size=13,
            color=NSColor.colorWithCalibratedWhite_alpha_(0.45, 1.0),
        )
        content.addSubview_(self.queue_summary)

        self.queue_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(sidebar_x, 350, 232, 150))
        self.queue_scroll.setBorderType_(NSNoBorder)
        self.queue_scroll.setHasVerticalScroller_(True)
        self.queue_scroll.setDrawsBackground_(False)
        self.queue_container = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 232, 150))
        self.queue_scroll.setDocumentView_(self.queue_container)
        content.addSubview_(self.queue_scroll)

        log_title = make_label(NSMakeRect(sidebar_x, 308, 200, 28), "Log console", font_size=18, bold=True)
        content.addSubview_(log_title)

        self.log_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(sidebar_x, 42, 232, 250))
        self.log_scroll.setBorderType_(NSNoBorder)
        self.log_scroll.setHasVerticalScroller_(True)
        self.log_scroll.setDrawsBackground_(False)
        self.log_container = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 232, 250))
        self.log_scroll.setDocumentView_(self.log_container)
        content.addSubview_(self.log_scroll)

    def _show_alert(self, title, message):
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title)
        alert.setInformativeText_(message)
        alert.addButtonWithTitle_("OK")
        alert.runModal()

    def _append_log(self, line):
        self._log_entries.append(line)
        self._log_entries = self._log_entries[-LOG_MAX_ENTRIES:]
        self._refresh_log_panel()

    def _queue_rows(self):
        rows = []
        if self._current_url:
            rows.append(("Running now", self._current_url))

        for index, queued_url in enumerate(self._job_queue, start=1):
            rows.append((f"Queued {index}", queued_url))

        if not rows:
            rows.append(("Queue empty", "Add a URL on the left to queue the next scrape."))

        return rows

    def _render_rows(self, container, rows, width, row_height, mono=False):
        for subview in list(container.subviews()):
            subview.removeFromSuperview()

        total_height = max(len(rows) * row_height, 1)
        container.setFrame_(NSMakeRect(0, 0, width, total_height))

        for index, row in enumerate(rows):
            y = total_height - ((index + 1) * row_height)
            title, body = row

            body_y = y + 10
            body_height = row_height - 18
            if title:
                title_label = make_label(
                    NSMakeRect(0, y + row_height - 22, width, 18),
                    title,
                    font_size=12,
                    bold=True,
                    color=NSColor.colorWithCalibratedWhite_alpha_(0.35, 1.0),
                )
                title_label.setLineBreakMode_(NSLineBreakByTruncatingTail)
                container.addSubview_(title_label)
                body_height = row_height - 26

            body_label = make_wrapped_label(
                NSMakeRect(0, body_y, width, body_height),
                body,
                font_size=13,
                mono=mono,
                color=NSColor.colorWithCalibratedWhite_alpha_(0.15, 1.0),
            )
            container.addSubview_(body_label)

            separator = NSBox.alloc().initWithFrame_(NSMakeRect(0, y, width, 1))
            separator.setBoxType_(NSBoxSeparator)
            container.addSubview_(separator)

    def _refresh_queue_panel(self):
        rows = self._queue_rows()
        pending = len(self._job_queue)
        if self._current_url:
            summary = f"1 running, {pending} pending"
        elif pending:
            summary = f"{pending} pending"
        else:
            summary = "No queued sites."

        self.queue_summary.setStringValue_(summary)
        self._render_rows(self.queue_container, rows, 220, 56, mono=False)

    def _refresh_log_panel(self):
        rows = [("", entry) for entry in self._log_entries[-8:]]
        if not rows:
            rows = [("", "Ready. Add a site to begin.")]
        self._render_rows(self.log_container, rows, 220, 68, mono=True)

    def _set_running(self, is_running, url=None):
        self._running = is_running
        self.progress.stopAnimation_(None)

        if is_running:
            self._current_url = url
            self.progress.startAnimation_(None)
            self.status_dot.setTextColor_(NSColor.systemBlueColor())
            self.status_label.setStringValue_(f"Status: Scraping")
            self.current_job_label.setStringValue_(url)
            self._append_log(f"Scraping {url}")
        else:
            self._current_url = None
            self.status_dot.setTextColor_(NSColor.systemGreenColor())
            self.status_label.setStringValue_("Status: Ready")
            self.current_job_label.setStringValue_("Nothing running right now.")

        self._refresh_queue_panel()

    def _enqueue_url(self, url):
        self._job_queue.append(url)
        self._append_log(f"Queued {url}")
        self._refresh_queue_panel()

        if not self._running:
            self._start_next_job()

    def _start_next_job(self):
        if self._running or not self._job_queue:
            if not self._running:
                self._refresh_queue_panel()
            return

        next_url = self._job_queue.popleft()
        self._set_running(True, next_url)
        thread = threading.Thread(target=self._run_scrape, args=(next_url,), daemon=True)
        thread.start()

    @objc.IBAction
    def scrapeClicked_(self, _sender):
        raw_url = self.url_field.stringValue().strip().rstrip("/")
        if not raw_url:
            self._show_alert("Missing URL", "Paste a portfolio URL first.")
            return

        url = raw_url if raw_url.startswith("http") else f"https://{raw_url}"
        self.url_field.setStringValue_("")
        self._enqueue_url(url)

    @objc.IBAction
    def openDesktopClicked_(self, _sender):
        subprocess.run(["open", str(Path.home() / "Desktop")], check=False)

    @objc.IBAction
    def openLastResultClicked_(self, _sender):
        if self._last_output_dir:
            subprocess.run(["open", self._last_output_dir], check=False)

    def _run_scrape(self, url):
        try:
            result = scrape_site(url, min_px=MIN_PX_DEFAULT)
            self._results.put(("success", result))
        except Exception as exc:
            self._results.put(("error", url, str(exc)))

    def pollResults_(self, _timer):
        while True:
            try:
                payload = self._results.get_nowait()
            except queue.Empty:
                return

            if payload[0] == "success":
                _, result = payload
                self._finish_success(result)
            else:
                _, url, error = payload
                self._finish_error(url, error)

    def _finish_success(self, result):
        self._set_running(False)
        self._last_output_dir = str(result.out_dir)
        self.open_last_button.setEnabled_(True)

        summary = [
            f"Platform: {result.platform}",
            f"Saved: {len(result.downloaded)}",
            f"Too small: {result.skipped_small}",
        ]
        if result.skipped_large:
            summary.append(f"Too large: {result.skipped_large}")
        if result.errors:
            summary.append(f"Failed: {result.errors}")

        self.status_label.setStringValue_(f"Status: Finished {result.studio}")
        self.status_dot.setTextColor_(NSColor.systemGreenColor())
        self.current_job_label.setStringValue_(f"Finished {result.studio}\nSaved to {result.out_dir}")
        self._append_log(f"Finished {result.studio}")
        self._append_log(" | ".join(summary))

        if self._job_queue:
            self._append_log(f"Continuing with {len(self._job_queue)} queued job(s).")
            self._start_next_job()
        else:
            subprocess.run(["open", str(result.out_dir)], check=False)
            self._refresh_queue_panel()

    def _finish_error(self, url, error):
        self._set_running(False)
        self.status_dot.setTextColor_(NSColor.systemRedColor())
        self.status_label.setStringValue_("Status: Error")
        self.current_job_label.setStringValue_(f"Failed on {url}")
        self._append_log(f"Error for {url}: {error}")

        if self._job_queue:
            self._append_log(f"Skipping to next queued job after failure on {url}.")
            self._start_next_job()
        else:
            self._show_alert("Scrape failed", error)
            self._refresh_queue_panel()


APP_DELEGATE = None


def main():
    global APP_DELEGATE

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    APP_DELEGATE = FolioScraperAppDelegate.alloc().init()
    app.setDelegate_(APP_DELEGATE)
    AppHelper.runEventLoop()


if __name__ == "__main__":
    main()
