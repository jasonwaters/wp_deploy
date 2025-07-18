#!/bin/bash

# ACF and Bricks Post-Deployment Diagnostic Script
# Run this on production to diagnose why ACF posts aren't rendering in Bricks

set -euo pipefail

# Load configuration from deploy_config.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy_config.sh"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please make sure deploy_config.sh exists in the same directory as this script."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cd "$PROD_PATH"

echo "ACF & Bricks Deployment Diagnostic"
echo "=================================="
echo "Production Path: $PROD_PATH"
echo "Stage URL: $STAGE_URL"
echo "Production URL: $PROD_URL"
echo ""

# Check WordPress connectivity
log "Checking WordPress connectivity..."
if wp core is-installed --allow-root 2>/dev/null; then
    log "✓ WordPress is accessible"
else
    log "✗ WordPress is not accessible via WP-CLI"
    exit 1
fi

# Check plugin status
log "Checking plugin status..."
if wp plugin is-active advanced-custom-fields --allow-root 2>/dev/null; then
    log "✓ ACF (free) is active"
elif wp plugin is-active advanced-custom-fields-pro --allow-root 2>/dev/null; then
    log "✓ ACF Pro is active"
else
    log "✗ ACF plugin is not active"
fi

if wp plugin is-active bricks --allow-root 2>/dev/null; then
    log "✓ Bricks is active"
else
    log "✗ Bricks plugin is not active"
fi

# Check for recent posts with ACF data
log "Checking recent posts with ACF data..."
recent_acf_posts=$(wp db query "
SELECT COUNT(*) as count
FROM wp_posts p
INNER JOIN wp_postmeta pm ON p.ID = pm.post_id
WHERE p.post_type = 'post'
AND p.post_status = 'publish'
AND pm.meta_key LIKE '%field_%'
AND p.post_date > DATE_SUB(NOW(), INTERVAL 30 DAY)
" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)

log "Found $recent_acf_posts recent posts with ACF data"

# Check for serialized data corruption
log "Checking for potential serialized data corruption..."
corrupted_meta=$(wp db query "
SELECT COUNT(*) as count
FROM wp_postmeta
WHERE meta_value LIKE 'a:%'
AND meta_value LIKE '%$STAGE_URL%'
" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)

if [[ "$corrupted_meta" -gt 0 ]]; then
    log "⚠ Found $corrupted_meta postmeta entries with serialized data containing stage URL"
    log "This indicates potential serialized data corruption"
fi

# Check specific ACF field data
log "Checking ACF field data integrity..."
wp eval "
if (function_exists('get_field')) {
    \$recent_posts = get_posts(array(
        'numberposts' => 5,
        'post_status' => 'publish',
        'date_query' => array(
            array(
                'after' => '30 days ago'
            )
        )
    ));

    \$issues = 0;
    foreach (\$recent_posts as \$post) {
        \$fields = get_fields(\$post->ID);
        if (empty(\$fields)) {
            \$issues++;
        }
    }

    echo 'Recent posts checked: ' . count(\$recent_posts) . '\n';
    echo 'Posts without ACF fields: ' . \$issues . '\n';
} else {
    echo 'ACF get_field function not available\n';
}
" --allow-root 2>/dev/null || log "ACF field check failed"

# Check Bricks templates
log "Checking Bricks templates..."
bricks_templates=$(wp db query "SELECT COUNT(*) as count FROM wp_posts WHERE post_type = 'bricks_template'" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
log "Found $bricks_templates Bricks templates"

# Check Bricks page content
log "Checking Bricks page content..."
bricks_pages=$(wp db query "SELECT COUNT(*) as count FROM wp_postmeta WHERE meta_key = '_bricks_page_content_2'" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
log "Found $bricks_pages pages/posts using Bricks"

# Check for Bricks cache
log "Checking Bricks cache status..."
bricks_cache_dirs=(
    "wp-content/uploads/bricks/css"
    "wp-content/uploads/bricks/js"
    "wp-content/cache/bricks"
)

for cache_dir in "${bricks_cache_dirs[@]}"; do
    if [[ -d "$cache_dir" ]]; then
        cache_files=$(find "$cache_dir" -type f | wc -l)
        log "Cache directory $cache_dir contains $cache_files files"
    else
        log "Cache directory $cache_dir does not exist"
    fi
done

# Quick fix suggestions
echo ""
echo "QUICK FIX SUGGESTIONS:"
echo "====================="

echo "1. Clear Bricks cache:"
echo "   rm -rf wp-content/uploads/bricks/css/*"
echo "   rm -rf wp-content/uploads/bricks/js/*"

echo ""
echo "2. Clear Bricks database cache:"
echo "   wp db query \"DELETE FROM wp_options WHERE option_name LIKE 'bricks_css_%' OR option_name LIKE 'bricks_js_%';\" --allow-root"

echo ""
echo "3. If serialized data is corrupted, re-run URL replacement:"
echo "   wp search-replace '$STAGE_URL' '$PROD_URL' --allow-root --skip-columns=guid"

echo ""
echo "4. Refresh ACF field groups:"
echo "   wp eval \"if (function_exists('acf_get_field_groups')) { \\\$groups = acf_get_field_groups(); foreach (\\\$groups as \\\$group) { if (function_exists('acf_sync_field_group')) acf_sync_field_group(\\\$group['key']); } }\" --allow-root"

echo ""
echo "5. Check a specific post manually:"
echo "   wp post get <POST_ID> --field=meta --allow-root"

log "Diagnostic completed"
