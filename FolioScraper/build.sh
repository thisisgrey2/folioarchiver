#!/bin/bash
set -euo pipefail

export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
APP_NAME="FolioArchiver"
APP_PRODUCT_NAME="FolioScraper"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
SWIFTPM_BUILD_DIR="$ROOT_DIR/build/swiftpm-release"
BUILD_PRODUCTS_DIR="$SWIFTPM_BUILD_DIR/apple/Products/Release"
BUILD_BINARY="$BUILD_PRODUCTS_DIR/$APP_PRODUCT_NAME"
CLI_NAME="folioscraper"
CLI_PRODUCT_NAME="FolioScraperCLI"
CLI_BINARY="$BUILD_PRODUCTS_DIR/$CLI_PRODUCT_NAME"
CLI_BUNDLE_NAME="folioscraper-cli"
CLI_GUIDE_NAME="FolioArchiver CLI.md"
CLI_GUIDE_PATH="$ROOT_DIR/dist/$CLI_GUIDE_NAME"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
INSTALLED_CLI_GUIDE="$INSTALL_DIR/$CLI_GUIDE_NAME"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.png"
ICON_NAME="AppIcon"
ICONSET_DIR="$ROOT_DIR/dist/$ICON_NAME.iconset"
ICON_OUTPUT="$ROOT_DIR/dist/$ICON_NAME.icns"

cleanup_generated_icons() {
    rm -rf "$ICONSET_DIR"
    rm -f "$ICON_OUTPUT"
}

sanitize_bundle_metadata() {
    local target="$1"
    /usr/bin/xattr -cr "$target" || true
    /usr/bin/xattr -d com.apple.FinderInfo "$target" || true
    /usr/bin/xattr -d com.apple.fileprovider.fpfs#P "$target" || true
    /usr/bin/xattr -d com.apple.provenance "$target" || true
    /usr/bin/dot_clean -m "$target" || true
    /usr/bin/xattr -cr "$target" || true
}

generate_app_icon() {
    if [ ! -f "$ICON_SOURCE" ]; then
        echo "WARNING: App icon source not found at $ICON_SOURCE"
        return
    fi

    mkdir -p "$ICONSET_DIR"

    local base_sizes=(16 32 128 256 512)
    for size in "${base_sizes[@]}"; do
        sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        local retina_size=$((size * 2))
        sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
}

write_cli_guide() {
    cat > "$CLI_GUIDE_PATH" <<EOF
# FolioArchiver CLI

FolioArchiver includes a bundled command-line tool for automated scraping.

## Use without installing anything

Run the bundled CLI directly from the app:

\`\`\`bash
"/Users/grey/Applications/$APP_NAME.app/Contents/MacOS/$CLI_BUNDLE_NAME" --help
\`\`\`

## Automatic terminal command

When you launch the app, it tries to install the \`$CLI_NAME\` terminal command automatically.

After that, you can run:

\`\`\`bash
$CLI_NAME --help
\`\`\`

If the app is moved and launched again, the command is refreshed automatically.
If the app is deleted, the command removes itself the next time you run it.

## Commands

### Scrape one site

\`\`\`bash
$CLI_NAME scrape https://example.com --max-images 200 --output "/path/to/output"
\`\`\`

Save a small markdown file with the studio name and URL:

\`\`\`bash
$CLI_NAME scrape https://example.com --max-images 200 --output "/path/to/output" --save-details
\`\`\`

### Scrape many sites from a text file

Put one URL per line in a file:

\`\`\`text
https://site-one.com
https://site-two.com
https://site-three.com
\`\`\`

Then run:

\`\`\`bash
$CLI_NAME batch urls.txt --max-images 200 --output "/path/to/output"
\`\`\`

You can add \`--save-details\` here too if you want a \`details.md\` file inside each site folder.

## Arguments

- \`scrape <url>\`: scrape one website
- \`batch <file>\`: scrape all URLs listed in a text file
- \`--max-images <count>\`: limit how many images to save per site. Valid range: \`1\` to \`1000\`.
- \`--output <folder>\`: choose where the site folders are saved
- \`--save-details\`: save a \`details.md\` file with the studio name and URL

## Notes

- The CLI uses the same scraping engine as the app.
- Output is grouped into one folder per site.
- If you do not pass \`--output\`, the default save location is your Desktop.
- Some heavily protected Cargo-hosted sites may still block direct media downloads even when rendered crawling can see the assets.
EOF
}

echo ""
echo "FolioArchiver Swift build"
echo "Project: $ROOT_DIR"
echo ""

echo "Swift: $(swift --version | head -n 1)"

echo ""
echo "Cleaning previous artifacts..."
rm -rf "$ROOT_DIR/build" "$ROOT_DIR/dist"
xattr -cr "$ROOT_DIR" || true

echo ""
echo "Building Swift release binary..."
swift build -c release --build-system xcode --build-path "$SWIFTPM_BUILD_DIR"

if [ ! -f "$BUILD_BINARY" ]; then
    echo ""
    echo "ERROR: Build failed. Expected binary not found at:"
    echo "  $BUILD_BINARY"
    exit 1
fi

if [ ! -f "$CLI_BINARY" ]; then
    echo ""
    echo "ERROR: CLI build failed. Expected binary not found at:"
    echo "  $CLI_BINARY"
    exit 1
fi

echo ""
echo "Packaging macOS app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$CLI_BINARY" "$APP_BUNDLE/Contents/MacOS/$CLI_BUNDLE_NAME"
generate_app_icon

if [ -f "$ICON_OUTPUT" ]; then
    cp "$ICON_OUTPUT" "$APP_BUNDLE/Contents/Resources/$ICON_NAME.icns"
fi
cleanup_generated_icons
write_cli_guide

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>FolioArchiver</string>
    <key>CFBundleExecutable</key>
    <string>FolioArchiver</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.grey.folioscraper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FolioArchiver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

sanitize_bundle_metadata "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto "$APP_BUNDLE" "$INSTALLED_APP"
cp "$CLI_GUIDE_PATH" "$INSTALLED_CLI_GUIDE"

echo ""
echo "Build complete."
echo "App bundle: $APP_BUNDLE"
echo "Installed to: $INSTALLED_APP"
echo ""
echo "Launch with:"
echo "  open \"$INSTALLED_APP\""
echo ""
