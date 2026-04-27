#!/bin/bash
APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/leanring-buddy-dvwepfgqqgvpjhbjcbybcytzaawt/Index.noindex/Build/Products/Debug/Clicky.app"

if [ -d "$APP_PATH" ]; then
    rm -rf "/Applications/Clicky.app" 2>/dev/null
    cp -R "$APP_PATH" /Applications/
    echo "✅ Clicky installed to /Applications!"
    echo "Now open Clicky from Applications folder and grant permissions."
else
    echo "❌ Clicky.app not found. Please build in Xcode first (⌘R)"
fi
