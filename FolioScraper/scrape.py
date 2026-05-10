#!/usr/bin/env python3
"""
folio_scraper — give it a URL, it saves hi-res images to ~/Desktop/<studio>/
Handles: standard sites, Next.js/DatoCMS, Wix, WordPress lazy-load, Cargo (via browser)

Usage:
    python scrape.py https://somesite.com
    python scrape.py https://somesite.com --min-px 800
"""

import argparse
import io
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, unquote, urljoin, urlparse

import requests
from bs4 import BeautifulSoup
from PIL import Image

# ── constants ─────────────────────────────────────────────────────────────────

MAX_IMAGES = 200
MAX_VIDEO_MB = 50
MAX_CRAWL_PAGES = 40
MIN_PX_DEFAULT = 1100

VIDEO_EXTS = {".mp4", ".mov", ".webm", ".m4v", ".ogv"}
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"}

SKIP_KEYWORDS = ["favicon", "avatar", "1x1", "blank", "spacer", "logo", "icon"]
SKIP_LINK_PATTERNS = (
    "/about",
    "/contact",
    "/privacy",
    "/legal",
    "/terms",
    "/policy",
    "/jobs",
    "/careers",
    "/feed",
    "/tag/",
    "/category/",
)

STRIP_QS_CDNS = (
    "https://www.datocms-assets.com/",
    "https://images.datocms-assets.com/",
    "https://images.ctfassets.net/",
    "https://cdn.sanity.io/",
)

SLUG_TEMPLATES = [
    "/work/{slug}",
    "/works/{slug}",
    "/projects/{slug}",
    "/case-studies/{slug}",
    "/case-study/{slug}",
    "/portfolio/{slug}",
]

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    )
}


@dataclass
class ScrapeResult:
    studio: str
    out_dir: Path
    downloaded: list[str]
    skipped_small: int
    skipped_large: int
    errors: int
    platform: str


# ── URL normalisation ─────────────────────────────────────────────────────────

def extract_real_url(url):
    if "/_next/image" in url:
        qs = parse_qs(urlparse(url).query)
        if "url" in qs:
            return unquote(qs["url"][0])
    return url


def upgrade_wix_url(url):
    match = re.match(
        r"(https://static\.wixstatic\.com/media/[^/]+~mv2\.[a-zA-Z]+)(?:/.*)?$",
        url,
    )
    if match:
        return match.group(1)

    match = re.match(
        r"(https://static\.wixstatic\.com/media/[^/]+\.[a-zA-Z]{3,4})(?:/v1/.*)?$",
        url,
    )
    if match:
        return match.group(1)

    return url


def strip_cdn_qs(url):
    if any(url.startswith(prefix) for prefix in STRIP_QS_CDNS):
        return url.split("?")[0]
    return url


def normalise(url, base):
    if not url:
        return None

    raw = url.strip()
    lowered = raw.lower()
    if lowered.startswith(("data:", "blob:", "mailto:", "tel:", "javascript:")):
        return None

    url = extract_real_url(urljoin(base, raw))
    url = upgrade_wix_url(url)
    url = strip_cdn_qs(url)
    return url


def studio_name_from_url(url):
    parsed = urlparse(url if url.startswith("http") else f"https://{url}")
    domain = parsed.netloc.lower().replace("www.", "").split(":")[0]
    studio = domain.split(".")[0] if domain else "portfolio"
    studio = re.sub(r"[^a-z0-9._-]+", "-", studio).strip("-")
    return studio or "portfolio"


def output_dir_for_url(url, output_root=None):
    root = Path(output_root).expanduser() if output_root else Path.home() / "Desktop"
    return root / studio_name_from_url(url)


def ensure_playwright_browser_path():
    if os.environ.get("PLAYWRIGHT_BROWSERS_PATH"):
        return

    resource_path = os.environ.get("RESOURCEPATH")
    if resource_path:
        bundled = Path(resource_path) / ".local-browsers"
        if bundled.is_dir():
            os.environ["PLAYWRIGHT_BROWSERS_PATH"] = str(bundled)
            return

    try:
        import playwright
    except ImportError:
        return

    package_browsers = Path(playwright.__file__).resolve().parent / "driver" / "package" / ".local-browsers"
    if package_browsers.is_dir():
        os.environ["PLAYWRIGHT_BROWSERS_PATH"] = str(package_browsers)


# ── site detection ────────────────────────────────────────────────────────────

def is_cargo(html, url):
    return "freight.cargo.site" in html or "cargo.site" in html


# ── HTML scraping helpers ─────────────────────────────────────────────────────

def get_candidates(html, base_url):
    soup = BeautifulSoup(html, "html.parser")
    found = set()

    for tag in soup.find_all("img"):
        for attr in ["src", "data-src", "data-lazy-src", "data-original"]:
            value = normalise(tag.get(attr), base_url)
            if value:
                found.add(value)

        for attr in ["srcset", "data-srcset"]:
            value = tag.get(attr)
            if not value:
                continue
            for part in value.split(","):
                candidate = normalise(part.strip().split()[0], base_url)
                if candidate:
                    found.add(candidate)

    for tag in soup.find_all("source"):
        for attr in ["src", "srcset"]:
            value = tag.get(attr)
            if not value:
                continue
            for part in value.split(","):
                candidate = normalise(part.strip().split()[0], base_url)
                if candidate:
                    found.add(candidate)

    for tag in soup.find_all("video"):
        for attr in ["src", "data-src"]:
            value = normalise(tag.get(attr), base_url)
            if value:
                found.add(value)

        poster = normalise(tag.get("poster"), base_url)
        if poster:
            found.add(poster)

    for tag in soup.find_all(style=True):
        for match in re.finditer(r'url\(["\']?(https://[^"\')\s]+)["\']?\)', tag["style"]):
            found.add(strip_cdn_qs(upgrade_wix_url(match.group(1))))

    for tag in soup.find_all("script"):
        if not tag.string:
            continue

        text = tag.string
        for match in re.finditer(r'https://static\.wixstatic\.com/media/[^"\'\s]+', text):
            found.add(upgrade_wix_url(match.group(0)))

        clean = text.replace('\\"', '"').replace("\\/", "/")
        for match in re.finditer(
            r'https://(?:www\.)?datocms-assets\.com/[^\s"\'<>&]+\.(?:jpg|jpeg|png|webp|avif|gif)',
            clean,
            re.IGNORECASE,
        ):
            found.add(match.group(0).split("?")[0])

        for match in re.finditer(r'https://[^\s"\']+\.(?:mp4|mov|webm|m4v)', text, re.IGNORECASE):
            found.add(match.group(0))

    return found


def get_internal_links(html, base_url):
    soup = BeautifulSoup(html, "html.parser")
    parsed_base = urlparse(base_url)
    origin = f"{parsed_base.scheme}://{parsed_base.netloc}"
    links = set()

    for tag in soup.find_all("a", href=True):
        href = tag["href"].strip()
        if href.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue

        candidate = urljoin(base_url, href).split("#")[0].split("?")[0]
        lowered = candidate.lower().rstrip("/")

        if not candidate.startswith(origin):
            continue
        if candidate.rstrip("/") == base_url.rstrip("/"):
            continue
        if any(pattern in lowered for pattern in SKIP_LINK_PATTERNS):
            continue

        links.add(candidate)

    return links


def get_rsc_slug_pages(html, base_url):
    if "self.__next_f" not in html:
        return set()

    text = html.replace('\\"', '"').replace("\\/", "/")
    nav_slugs = {
        "about",
        "contact",
        "insights",
        "news",
        "blog",
        "privacy",
        "privacy-policy",
        "imprint",
        "legal",
        "careers",
        "jobs",
        "services",
        "service",
        "team",
        "product-design",
        "brands",
        "content",
        "code-of-conduct",
    }

    slugs = [
        slug
        for slug in dict.fromkeys(re.findall(r'"slug"\s*:\s*"([a-z0-9][a-z0-9\-]+)"', text))
        if slug not in nav_slugs and len(slug) > 2
    ]
    if not slugs:
        return set()

    parsed = urlparse(base_url)
    base_path = parsed.path.rstrip("/")
    origin = f"{parsed.scheme}://{parsed.netloc}"
    confirmed = set()

    for slug in slugs:
        for template in SLUG_TEMPLATES:
            url = origin + base_path + template.format(slug=slug)
            try:
                response = requests.head(url, headers=HEADERS, timeout=8, allow_redirects=True)
                if response.status_code == 200:
                    confirmed.add(url)
                    break
            except Exception:
                continue

    return confirmed


# ── WordPress: get full-size from attachment page ─────────────────────────────

def upgrade_wp_image_urls(candidates):
    """Swap common WordPress crop URLs for their original uploads path."""
    upgraded = set()
    for url in candidates:
        match = re.match(
            r"(https?://[^/]+/wp-content/uploads/\d{4}/\d{2}/)(.+?)(-\d+x\d+)(\.[a-z]+)$",
            url,
            re.I,
        )
        if match:
            upgraded.add(match.group(1) + match.group(2) + match.group(4))
        else:
            upgraded.add(url)
    return upgraded


# ── file helpers ──────────────────────────────────────────────────────────────

def unique_path(directory, fname):
    fpath = Path(directory) / fname
    base, ext = os.path.splitext(fname)
    n = 1
    while fpath.exists():
        fpath = Path(directory) / f"{base}_{n}{ext}"
        n += 1
    return str(fpath)


def should_skip(url):
    lowered = url.lower()
    return any(keyword in lowered for keyword in SKIP_KEYWORDS) or lowered.endswith(".svg") or lowered.endswith(".ico")


def dedupe_by_path(urls):
    seen_paths = set()
    deduped = set()

    for url in urls:
        path = urlparse(url).path
        if path and path not in seen_paths:
            seen_paths.add(path)
            deduped.add(url)

    return deduped


# ── standard (requests-based) scrape ─────────────────────────────────────────

def scrape_standard(start_url, out_dir, min_px):
    session = requests.Session()
    session.headers.update(HEADERS)

    pages_to_crawl = {start_url}
    crawled = set()
    all_candidates = set()

    while pages_to_crawl and len(crawled) < MAX_CRAWL_PAGES:
        url = pages_to_crawl.pop()
        if url in crawled:
            continue

        crawled.add(url)
        print(f"  Crawling: {url}")

        try:
            response = session.get(url, timeout=15)
            response.raise_for_status()
            html = response.text
            all_candidates |= get_candidates(html, url)
            if url == start_url:
                pages_to_crawl |= get_internal_links(html, start_url)
                pages_to_crawl |= get_rsc_slug_pages(html, start_url)
        except Exception as exc:
            print(f"    Error: {exc}")

    deduped = dedupe_by_path(all_candidates)
    deduped = upgrade_wp_image_urls(deduped)

    print(f"\n  {len(deduped)} unique candidates — downloading...\n")
    return _download_all(deduped, out_dir, min_px, session)


# ── Cargo (Playwright-based) scrape ──────────────────────────────────────────

def scrape_cargo(start_url, out_dir, min_px):
    ensure_playwright_browser_path()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("\n  ERROR: Playwright not installed.")
        print("  Run: pip install playwright && playwright install chromium\n")
        sys.exit(1)

    domain = urlparse(start_url).netloc
    print(f"  Cargo site detected ({domain}) — launching browser...")

    all_image_urls = set()

    with sync_playwright() as playwright_ctx:
        browser = playwright_ctx.chromium.launch(headless=True)
        context = browser.new_context(user_agent=HEADERS["User-Agent"])
        page = context.new_page()

        page.goto(start_url, wait_until="networkidle", timeout=30000)

        slugs = page.evaluate(
            """() => {
                const scripts = document.querySelectorAll('script[type="text/json"]');
                const slugs = new Set();
                scripts.forEach(s => {
                    try {
                        const data = JSON.parse(s.textContent);
                        const pages = data.pages || [];
                        pages.forEach(p => {
                            if (p.project_url && p.display !== false) {
                                slugs.add(p.project_url);
                            }
                        });
                        if (Array.isArray(data)) {
                            data.forEach(p => p.url && slugs.add(p.url));
                        }
                    } catch (e) {}
                });
                return [...slugs];
            }"""
        )

        more_slugs = page.evaluate(
            """() => {
                const scripts = document.querySelectorAll(
                    'script[type="text/json"][data-set="FirstloadThumbnails"]'
                );
                const slugs = new Set();
                scripts.forEach(s => {
                    try {
                        const data = JSON.parse(s.textContent);
                        if (Array.isArray(data)) data.forEach(p => p.url && slugs.add(p.url));
                    } catch (e) {}
                });
                return [...slugs];
            }"""
        )

        all_slugs = list(set(slugs + more_slugs))
        print(f"  Found {len(all_slugs)} project pages to crawl")

        parsed = urlparse(start_url)
        origin = f"{parsed.scheme}://{parsed.netloc}"

        def extract_images_from_page():
            return page.evaluate(
                """() => {
                    const urls = new Set();

                    document.querySelectorAll('[data-src]').forEach(el => {
                        const src = el.getAttribute('data-src');
                        if (src && src.includes('freight.cargo.site') &&
                            !src.endsWith('.svg') && !src.endsWith('.ico')) {
                            urls.add(src);
                        }
                    });

                    document.querySelectorAll('img[src]').forEach(el => {
                        const src = el.src;
                        if (src && src.includes('freight.cargo.site') &&
                            !src.endsWith('.svg') && !src.endsWith('.ico')) {
                            urls.add(src);
                        }
                    });

                    document.querySelectorAll('script[type="text/json"]').forEach(s => {
                        const matches = s.textContent.match(
                            /https:\\/\\/freight\\.cargo\\.site\\/t\\/original\\/[^"'\\s<>]+\\.(?:jpg|jpeg|png|gif|JPG|JPEG|PNG)/g
                        );
                        if (matches) matches.forEach(m => urls.add(m));
                    });

                    return [...urls];
                }"""
            )

        imgs = extract_images_from_page()
        all_image_urls.update(imgs)

        for slug in all_slugs[:MAX_CRAWL_PAGES]:
            url = f"{origin}/{slug.lstrip('/')}"
            print(f"  Crawling: {url}")
            try:
                page.goto(url, wait_until="networkidle", timeout=20000)
                imgs = extract_images_from_page()
                all_image_urls.update(imgs)
                print(f"    +{len(imgs)} images (total: {len(all_image_urls)})")
            except Exception as exc:
                print(f"    Error: {exc}")

        cookies = context.cookies()
        browser.close()

    deduped = dedupe_by_path(all_image_urls)

    print(f"\n  {len(deduped)} unique images — downloading...\n")

    session = requests.Session()
    session.headers.update(HEADERS)
    for cookie in cookies:
        session.cookies.set(cookie["name"], cookie["value"], domain=cookie.get("domain", ""))

    return _download_all(deduped, out_dir, min_px, session)


# ── shared download logic ─────────────────────────────────────────────────────

def _download_all(candidates, out_dir, min_px, session):
    downloaded, skipped_small, skipped_large, errors = [], 0, 0, 0

    for media_url in sorted(candidates):
        if len(downloaded) >= MAX_IMAGES:
            print(f"  — cap of {MAX_IMAGES} reached, stopping.")
            break

        if should_skip(media_url):
            continue

        ext = os.path.splitext(urlparse(media_url).path)[1].lower()

        if ext in VIDEO_EXTS:
            try:
                head = session.head(media_url, timeout=10, allow_redirects=True)
                cl = head.headers.get("Content-Length")
                if cl and int(cl) > MAX_VIDEO_MB * 1024 * 1024:
                    print(f"  — skip video (too large)  {os.path.basename(media_url)}")
                    skipped_large += 1
                    continue

                response = session.get(media_url, timeout=60, stream=True)
                response.raise_for_status()

                chunks, total, too_big = [], 0, False
                for chunk in response.iter_content(256 * 1024):
                    total += len(chunk)
                    if total > MAX_VIDEO_MB * 1024 * 1024:
                        too_big = True
                        break
                    chunks.append(chunk)

                if too_big:
                    skipped_large += 1
                    continue

                fname = os.path.basename(urlparse(media_url).path) or f"video_{len(downloaded) + 1}{ext}"
                fpath = unique_path(out_dir, fname)
                with open(fpath, "wb") as file_obj:
                    for chunk in chunks:
                        file_obj.write(chunk)
                print(f"  ✓ video {total / 1024 / 1024:.1f}MB  {fname}")
                downloaded.append(fpath)
            except Exception as exc:
                print(f"  ✗ {os.path.basename(media_url)}: {exc}")
                errors += 1

        elif ext in IMAGE_EXTS or not ext:
            try:
                response = session.get(media_url, timeout=20)
                response.raise_for_status()
                img = Image.open(io.BytesIO(response.content))
                width, height = img.size
                if width < min_px and height < min_px:
                    skipped_small += 1
                    continue

                fname = os.path.basename(urlparse(media_url).path) or f"image_{len(downloaded) + 1}.jpg"
                fpath = unique_path(out_dir, fname)
                with open(fpath, "wb") as file_obj:
                    file_obj.write(response.content)
                print(f"  ✓ {width}x{height}  {fname}")
                downloaded.append(fpath)
            except Exception as exc:
                print(f"  ✗ {os.path.basename(media_url)}: {exc}")
                errors += 1

    return downloaded, skipped_small, skipped_large, errors


def scrape_site(start_url, min_px=MIN_PX_DEFAULT, output_root=None):
    start_url = start_url.rstrip("/")
    if not start_url.startswith("http"):
        start_url = f"https://{start_url}"

    studio = studio_name_from_url(start_url)
    out_dir = output_dir_for_url(start_url, output_root)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        probe = requests.get(start_url, headers=HEADERS, timeout=15)
        probe.raise_for_status()
        html = probe.text
    except Exception as exc:
        raise RuntimeError(f"Could not reach {start_url}: {exc}") from exc

    if is_cargo(html, start_url):
        platform = "Cargo"
        downloaded, skipped_small, skipped_large, errors = scrape_cargo(start_url, str(out_dir), min_px)
    else:
        platform = "Standard"
        downloaded, skipped_small, skipped_large, errors = scrape_standard(start_url, str(out_dir), min_px)

    return ScrapeResult(
        studio=studio,
        out_dir=out_dir,
        downloaded=downloaded,
        skipped_small=skipped_small,
        skipped_large=skipped_large,
        errors=errors,
        platform=platform,
    )


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Folio image scraper")
    parser.add_argument("url", help="Portfolio URL to scrape")
    parser.add_argument(
        "--min-px",
        type=int,
        default=MIN_PX_DEFAULT,
        help=f"Min image dimension in pixels (default: {MIN_PX_DEFAULT})",
    )
    args = parser.parse_args()

    start_url = args.url.rstrip("/")
    if not start_url.startswith("http"):
        start_url = f"https://{start_url}"

    out_dir = output_dir_for_url(start_url)

    print(f"\n{'─' * 50}")
    print(f"  Studio : {studio_name_from_url(start_url)}")
    print(f"  URL    : {start_url}")
    print(f"  Output : {out_dir}")
    print(f"  Min px : {args.min_px}")
    print(f"{'─' * 50}\n")

    try:
        result = scrape_site(start_url, min_px=args.min_px)
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        sys.exit(1)

    print(f"\n{'─' * 50}")
    print(f"  Platform   : {result.platform}")
    print(f"  Downloaded : {len(result.downloaded)}")
    print(f"  Too small  : {result.skipped_small}")
    print(f"  Too large  : {result.skipped_large}")
    print(f"  Errors     : {result.errors}")
    print(f"  Saved to   : {result.out_dir}")
    print(f"{'─' * 50}\n")


if __name__ == "__main__":
    main()
