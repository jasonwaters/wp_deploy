#!/bin/bash

# Quick Bricks Cache Fix
# Run this on production after deployment if ACF posts aren't rendering

PROD_PATH="${1:-$(pwd)}"

echo "Clearing Bricks cache on: $PROD_PATH"

cd "$PROD_PATH"

# 1. Remove Bricks cache files
echo "Removing Bricks cache files..."
rm -rf wp-content/uploads/bricks/css/* 2>/dev/null || true
rm -rf wp-content/uploads/bricks/js/* 2>/dev/null || true

# 2. Clear Bricks database cache
echo "Clearing Bricks database cache..."
wp db query "DELETE FROM wp_options WHERE option_name LIKE 'bricks_css_%' OR option_name LIKE 'bricks_js_%';" --allow-root 2>/dev/null || true

# 3. Clear Bricks transients
wp db query "DELETE FROM wp_options WHERE option_name LIKE '_transient_bricks_%';" --allow-root 2>/dev/null || true

# 4. Flush WordPress cache
wp cache flush --allow-root 2>/dev/null || true

echo "✓ Bricks cache cleared. Try refreshing your site now."
