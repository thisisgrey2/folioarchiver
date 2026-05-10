# Scraper Timeline

This document describes the current scrape process in the order it happens today.

It is based on the live code in:

- `/Users/grey/Documents/Grey/Design/Works/Independent/Folio scrapper/Codex/FolioScraper/Sources/FolioScraperCore/PortfolioScraperService.swift`
- `/Users/grey/Documents/Grey/Design/Works/Independent/Folio scrapper/Codex/FolioScraper/Sources/FolioScraperCore/RenderedPageCrawler.swift`

## 1. Scrape starts

The app receives:

- `startURL`
- `maxImages`
- `outputRoot`
- `saveDetails`
- `downloadSmallImages`

Then it immediately:

1. normalizes the start URL
2. derives the studio name from the host
3. creates the output folder
4. creates a `Media` subfolder inside the studio folder
5. optionally writes `details.md` in the studio folder root

At this point, no media has been discovered or downloaded yet.

## 2. Crawl queue is created

The crawler starts with:

- `toCrawl = [normalizedStartURL]`
- `crawled = []`
- `allCandidates = [:]`

`allCandidates` is a dictionary:

- key = asset URL
- value = source page URL used as referer

This means discovery already keeps some source-page context for later downloads.

## 3. Each page is crawled

For each URL in `toCrawl`, the app does this:

1. mark the page as crawled
2. try a rendered crawl with `WKWebView`
3. if rendering works, merge rendered results
4. also try a raw HTML fetch for the same page and merge those results too
5. if rendering fails, fall back to raw HTML only

The crawl stops after `maxCrawlPages = 40`.

## 4. Rendered crawl path

When the rendered crawl succeeds, `RenderedPageCrawler` does this:

1. creates an offscreen `WKWebView`
2. loads the page
3. waits for the page to settle
4. auto-scrolls the page
5. tries to activate video content
6. auto-scrolls again
7. captures:
   - final rendered HTML
   - asset candidates from the DOM
   - internal link candidates from the DOM

Important detail:

- The rendered crawl is used for discovery only.
- It does not itself save files.

## 5. Raw HTML extraction path

After a successful rendered crawl, the app still also tries a normal HTML fetch for the same page.

This raw HTML is used to discover:

- normal image URLs
- video URLs
- CSS background URLs
- Sanity image references
- internal links
- Cargo project links
- slug-based pages for some Next.js-style sites

So the app currently merges two discovery sources:

- rendered DOM discovery
- raw HTML discovery

## 6. Candidate discovery

The app extracts candidates from several places:

- `src`, `data-src`, `data-lazy-src`, `data-original`, `poster`
- `srcset`, `data-srcset`
- CSS `url(...)`
- some hardcoded CDN patterns
- direct video URLs
- Sanity image refs converted into real CDN URLs

At this stage, the app is still only collecting URLs.

No media bytes are downloaded yet.

## 7. Internal link discovery

The app also extracts more pages to crawl from:

- `href` attributes
- rendered DOM links
- Cargo `project_url` values
- slug heuristics for some JS sites

Only same-origin URLs that look like real pages are queued.

Non-page assets like `.css`, `.js`, `.json`, images, and videos should be excluded from the crawl queue.

## 8. All discovered asset URLs are merged

Every discovered asset URL is merged into `allCandidates`.

If the same asset URL is found from multiple pages:

- the app keeps one referer
- it may replace the old referer if the new one is considered better

This is still discovery-level dedupe only.

It is deduping identical URLs, not identical images.

## 9. URL upgrade and variant reduction

Before download starts, the app transforms and reduces candidate URLs.

### 9a. Upgrade some URLs

It upgrades some URLs first, such as:

- WordPress resized uploads
- Wix image URLs
- Next.js image wrappers

### 9b. Collapse obvious size variants

Then it calls `selectLargestAssetVariants(...)`.

This is the first true dedupe stage.

It is URL-based, not pixel-based.

The app:

1. computes a canonical asset key for each URL
2. strips some size-related query params and path patterns
3. estimates a resolution score from the URL
4. keeps only the largest-scoring URL for each canonical key

This is intended to catch cases like:

- same asset at multiple widths
- WordPress resized variants
- Cargo original vs width variant

Important limitation:

- If two URLs do not normalize to the same canonical key, they both survive this stage.

## 10. Download loop begins

After URL-level reduction, the app creates a list of `AssetCandidate` values:

- asset URL
- referer URL

Then it starts downloading candidates one by one until:

- it runs out of candidates
- or it has saved `maxImages`

There is no parallel download step in the current flow.

## 11. Each candidate is attempted directly

There is currently no keyword-based skip filter before download.

If a URL survives discovery and URL-level variant reduction, the app attempts to download it.

## 12. Video path

If the file extension looks like a video:

1. do a `HEAD` request if possible
2. skip if declared size is above `50 MB`
3. fetch the asset bytes
4. skip if actual data is above `50 MB`
5. save the file directly

Videos do not go through perceptual fingerprint dedupe.

## 13. Image path

If the candidate is treated as an image:

1. fetch the asset bytes
2. reject empty payloads
3. choose a preferred filename
4. if AVIF, optionally create a temporary PNG analysis copy
5. decode the analysis image into pixels
6. read width and height
7. if small images are not allowed and longest side is below `900`, skip it
8. try to build an image fingerprint

So the fingerprint step happens before the image is saved permanently.

## 14. How image download works

The app tries several download methods in this order:

1. `URLSession`
2. `curl` fallback for some HTTP failures
3. rendered WebKit image load fallback for some blocked image URLs

If all fail, the candidate counts as an error.

## 15. Fingerprint generation

If decoding succeeds, the app builds an `ImageFingerprint`.

The current fingerprint stores:

- `redHash`
- `greenHash`
- `blueHash`
- `width`
- `height`

The fingerprint is based on a decoded image, not on raw file bytes.

So two visually identical files in different formats can still compare as duplicates if decoding succeeds for both.

The duplicate match itself uses:

- `redHash`
- `greenHash`
- `blueHash`

The stored `width` and `height` are not used to decide whether two images match.

They are only used afterward to decide which duplicate to keep.

Important limitation:

- If decoding fails, the image may still be saved without a fingerprint.
- That means some duplicates can bypass perceptual dedupe entirely.

## 16. Image duplicate check

The app keeps an in-memory array of saved image records during the scrape:

- saved file URL
- fingerprint

When a new image has a fingerprint, the app compares it against already-saved fingerprinted images.

If it finds a near-duplicate:

1. compare pixel area
2. keep the larger image
3. discard the smaller image

If the new image is larger:

1. remove the old saved file from disk
2. save the new image
3. replace the old record in memory

If the new image is smaller:

1. do not save the new image

Important detail:

- This duplicate comparison only happens against images that already have usable fingerprints.
- Non-fingerprinted images are not part of this perceptual comparison set.

## 17. Permanent save

Only after the duplicate decision is made, the app writes the winning image to disk.

The saved image is also:

- added to `downloaded`
- added to `savedImageRecords` if it has a fingerprint
- saved inside the studio's `Media` folder

So the intended order is:

1. fetch
2. decode
3. fingerprint
4. compare against prior fingerprinted saves
5. decide winner
6. save winner

## 18. End of scrape

When the loop ends, the app returns:

- studio name
- output folder
- number of found candidates
- downloaded file URLs
- skipped small count
- skipped large count
- error count
- platform label

## Current duplicate-control points

Right now duplicates are controlled in two separate places:

### Stage A: URL-level variant reduction

This happens before download.

Goal:

- collapse obvious resized or CDN variant URLs

Strength:

- cheap
- catches exact asset families

Weakness:

- only works when the URLs normalize to the same canonical key

### Stage B: Fingerprint-level image dedupe

This happens after download analysis but before permanent save.

Goal:

- catch visually identical images even when URLs differ

Strength:

- works across formats and resolution changes if decoding works

Weakness:

- depends on successful decode and fingerprint generation
- does not help for videos
- does not compare against images that were saved without fingerprints

## Most relevant questions for the duplicate bug

If duplicate images are still appearing, the most likely places to investigate are:

1. URL-level canonicalization is not collapsing some variant URLs
2. some images are being saved without usable fingerprints
3. some images are not considered near-duplicates by the current fingerprint threshold
4. some duplicate families differ enough in crop, encoding, or decode behavior that the current image fingerprint does not match them

## Short version

The current intended image order is:

1. discover URLs
2. reduce obvious URL variants
3. download image bytes
4. decode image
5. skip if too small
6. compute fingerprint if possible
7. compare against already-saved fingerprinted images
8. keep only the larger duplicate
9. save the winner

That means duplicate prevention is supposed to happen before final save, not after.
