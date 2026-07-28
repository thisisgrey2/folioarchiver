# FolioArchiver

FolioArchiver is a native macOS app for archiving the media from artist, designer, and studio portfolio websites. Add portfolio URLs to a queue and the app saves the available images, short-form videos, and optional site details into organised folders on your Desktop.

It is designed for completeness rather than speed. The scraper renders modern sites, follows same-site project pages, handles lazy-loaded galleries, and understands public Cargo project catalogues. Duplicate detection is always on: exact copies are skipped, while larger or better-quality versions can replace smaller versions of the same image.

## What it does

- Queues multiple portfolio sites and processes them one at a time.
- Finds media on the main page and linked project pages.
- Supports public Cargo sites as well as standard HTML, JavaScript-rendered, and lazy-loaded galleries.
- Saves media to `~/Desktop/<site-name>/Media/`.
- Can save a `details.md` file containing the studio name and source URL.
- Avoids duplicate downloads while retaining the best available version.
- Downloads videos by default; turn off **Download videos** in the app when you only want images.

## Build the app

From this project folder:

```bash
bash build.sh
```

The packaged application is created here:

```text
dist/FolioArchiver.app
```

It remains in the project’s `dist` folder; the build does not install it into `Applications` or another shared location.

Launch it with:

```bash
open "dist/FolioArchiver.app"
```

## Use the app

1. Open `FolioArchiver.app`.
2. Paste an artist, designer, or studio portfolio URL.
3. Click **Add to queue**.
4. Adjust the image limit or other options if needed.
5. Let the queue complete and find each archive on your Desktop.

The image-limit choices are 200, 400, 800, and 1500 images per site. Media that has already been identified as a duplicate is not saved again.

## Command line tool

The app includes `folioscraper`, a command-line tool using the same archive engine. Launching the app attempts to make it available automatically. A usage guide is included beside the packaged app in `dist/FolioArchiver CLI.md`.

## Notes

- Downloads are handled as independent archive runs; the app does not retain a permanent history of previously archived sites.
- Very large long-form videos are intentionally excluded to keep portfolio archives manageable.
- Sites can restrict public access to their media. When that happens, FolioArchiver records the failure and continues with the next item or queued site.
