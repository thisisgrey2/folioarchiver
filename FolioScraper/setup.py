from setuptools import setup

APP = ["app.py"]

OPTIONS = {
    "argv_emulation": False,
    "iconfile": None,
    "includes": ["scrape", "playwright.sync_api", "AppKit", "Foundation", "PyObjCTools"],
    "packages": ["requests", "bs4", "PIL"],
    "plist": {
        "CFBundleIdentifier": "com.grey.folioscraper",
        "CFBundleName": "FolioScraper",
        "CFBundleDisplayName": "Folio Scraper",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1.0.0",
        "LSUIElement": False,
        "NSUserNotificationAlertStyle": "alert",
    },
    "resources": [],
    "site_packages": True,
    "excludes": [
        "tkinter",
        "playwright._impl.__pyinstaller",
        "playwright._impl.__pyinstaller.hook-playwright.async_api",
        "playwright._impl.__pyinstaller.hook-playwright.sync_api",
    ],
}

setup(
    app=APP,
    name="FolioScraper",
    options={"py2app": OPTIONS},
)
