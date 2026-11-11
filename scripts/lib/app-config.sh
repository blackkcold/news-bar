#!/bin/bash
# Shared build and release constants. Sourced by build.sh, package-local.sh
# and appcast.sh; never executed on its own.

APP_NAME="NewsBar"
BUNDLE_ID="com.newsbar.app"
REPO_SLUG="blackkcold/news-bar"

# The fixed signing identity. Its certificate leaf is the app's designated
# requirement, so it must never be regenerated: a new certificate resets every
# TCC grant, notification permission and login-item approval.
SIGN_IDENTITY="${NEWSBAR_SIGN_IDENTITY:-NewsBar Code Signing}"
SIGNING_DIR="${NEWSBAR_SIGNING_DIR:-$HOME/.config/newsbar/signing}"

# Sparkle feed + EdDSA public key. The private half never enters the repo.
SU_FEED_URL="https://github.com/${REPO_SLUG}/releases/latest/download/appcast.xml"
SU_PUBLIC_ED_KEY="pysGE+4GDqzPuFgK6lpOlTJuvfnqCdjyJ0bVdOiUHsY="
