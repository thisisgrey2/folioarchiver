# Folio Scraper

Folio Scraper is now a native macOS app written in Swift and SwiftUI.

It keeps the desktop-window workflow we built together:

- fixed-size window
- URL queueing
- sidebar queue list
- sidebar log console
- automatic handoff from one scrape job to the next

## Build the app

From the project folder:

```bash
bash build.sh
```

That will:

1. Build the Swift release binary with Swift Package Manager
2. Package `dist/FolioScraper.app`
3. Copy the app into `~/Applications/FolioScraper.app`

Launch it with:

```bash
open ~/Applications/FolioScraper.app
```

## Use the app

1. Open the app
2. Paste an artist or designer portfolio URL
3. Click `Add To Queue`
4. Add more URLs if you want
5. Watch the queue and log panels on the right

Downloads are saved to:

```text
~/Desktop/<site-name>/
```

## Notes

- The native app and queue UI are Swift.
- The old Python files are still in the repo as reference while we complete the migration.
- The current Swift scraper handles standard HTML extraction well.
- Some heavily protected Cargo-hosted sites may still block direct media downloads even when rendered crawling can see the assets.
