#!/bin/bash

# WordPress URL Validation Script
# This script checks for any remaining STAGE_URL references in the production database

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy_config.sh"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please copy deploy_config.sh.example to deploy_config.sh and configure it."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# =============================================================================
# VALIDATION FUNCTION
# =============================================================================

validate_url_replacement() {
    log "Validating URL replacement - checking for any remaining STAGE_URL references..."

    cd "$PROD_PATH"

    local validation_errors=0
    local total_stage_refs=0

    # Check wp_options table for any remaining stage URLs
    log "Checking wp_options table..."
    local options_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$options_stage_count" =~ ^[0-9]+$ ]] && [[ "$options_stage_count" -gt 0 ]]; then
        log "WARNING: Found $options_stage_count references to STAGE_URL in wp_options table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + options_stage_count))

        # Show specific problematic entries
        log "Problematic wp_options entries:"
        wp db query "SELECT option_name, option_value FROM wp_options WHERE option_value LIKE '%$STAGE_URL%' LIMIT 10;" --allow-root 2>/dev/null | head -20
    else
        log "✓ wp_options table: No STAGE_URL references found"
    fi

    # Check wp_posts table for any remaining stage URLs
    log "Checking wp_posts table..."
    local posts_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_posts WHERE post_content LIKE '%$STAGE_URL%' OR post_excerpt LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$posts_stage_count" =~ ^[0-9]+$ ]] && [[ "$posts_stage_count" -gt 0 ]]; then
        log "WARNING: Found $posts_stage_count references to STAGE_URL in wp_posts table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + posts_stage_count))

        # Show specific problematic entries
        log "Problematic wp_posts entries:"
        wp db query "SELECT ID, post_title, post_type FROM wp_posts WHERE post_content LIKE '%$STAGE_URL%' OR post_excerpt LIKE '%$STAGE_URL%' LIMIT 10;" --allow-root 2>/dev/null | head -20
    else
        log "✓ wp_posts table: No STAGE_URL references found"
    fi

    # Check wp_postmeta table for any remaining stage URLs
    log "Checking wp_postmeta table..."
    local postmeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_postmeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$postmeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$postmeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $postmeta_stage_count references to STAGE_URL in wp_postmeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + postmeta_stage_count))

        # Show specific problematic entries
        log "Problematic wp_postmeta entries:"
        wp db query "SELECT post_id, meta_key, meta_value FROM wp_postmeta WHERE meta_value LIKE '%$STAGE_URL%' LIMIT 10;" --allow-root 2>/dev/null | head -20
    else
        log "✓ wp_postmeta table: No STAGE_URL references found"
    fi

    # Check wp_comments table for any remaining stage URLs
    log "Checking wp_comments table..."
    local comments_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_comments WHERE comment_content LIKE '%$STAGE_URL%' OR comment_author_url LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$comments_stage_count" =~ ^[0-9]+$ ]] && [[ "$comments_stage_count" -gt 0 ]]; then
        log "WARNING: Found $comments_stage_count references to STAGE_URL in wp_comments table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + comments_stage_count))

        # Show specific problematic entries
        log "Problematic wp_comments entries:"
        wp db query "SELECT comment_ID, comment_author, comment_content FROM wp_comments WHERE comment_content LIKE '%$STAGE_URL%' OR comment_author_url LIKE '%$STAGE_URL%' LIMIT 10;" --allow-root 2>/dev/null | head -20
    else
        log "✓ wp_comments table: No STAGE_URL references found"
    fi

    # Check wp_commentmeta table for any remaining stage URLs
    log "Checking wp_commentmeta table..."
    local commentmeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_commentmeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$commentmeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$commentmeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $commentmeta_stage_count references to STAGE_URL in wp_commentmeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + commentmeta_stage_count))
    else
        log "✓ wp_commentmeta table: No STAGE_URL references found"
    fi

    # Check wp_usermeta table for any remaining stage URLs
    log "Checking wp_usermeta table..."
    local usermeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_usermeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$usermeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$usermeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $usermeta_stage_count references to STAGE_URL in wp_usermeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + usermeta_stage_count))
    else
        log "✓ wp_usermeta table: No STAGE_URL references found"
    fi

    # Check for HTTPS variants as well
    log "Checking for HTTPS variants of STAGE_URL..."
    local https_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%https://$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$https_stage_count" =~ ^[0-9]+$ ]] && [[ "$https_stage_count" -gt 0 ]]; then
        log "WARNING: Found $https_stage_count references to https://$STAGE_URL"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + https_stage_count))
    fi

    local http_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%http://$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$http_stage_count" =~ ^[0-9]+$ ]] && [[ "$http_stage_count" -gt 0 ]]; then
        log "WARNING: Found $http_stage_count references to http://$STAGE_URL"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + http_stage_count))
    fi

    # Verify that production URLs are present
    log "Verifying production URLs are present..."
    local prod_url_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%$PROD_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$prod_url_count" =~ ^[0-9]+$ ]] && [[ "$prod_url_count" -gt 0 ]]; then
        log "✓ Found $prod_url_count references to PROD_URL in database"
    else
        log "WARNING: No references to PROD_URL found in database - this may indicate a problem"
        validation_errors=$((validation_errors + 1))
    fi

    # Summary
    echo ""
    echo "=========================================="
    echo "URL VALIDATION SUMMARY"
    echo "=========================================="
    echo "Stage URL: $STAGE_URL"
    echo "Production URL: $PROD_URL"
    echo "Production Path: $PROD_PATH"
    echo ""

    if [[ "$validation_errors" -eq 0 ]]; then
        echo "✓ VALIDATION PASSED: All STAGE_URL references have been successfully replaced"
        echo "=========================================="
        return 0
    else
        echo "⚠ VALIDATION FAILED: Found $total_stage_refs total STAGE_URL references across $validation_errors table(s)"
        echo ""
        echo "Manual cleanup may be required for the remaining references shown above."
        echo "You can run the following commands to attempt cleanup:"
        echo ""
        echo "wp db query \"UPDATE wp_options SET option_value = REPLACE(option_value, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo "wp db query \"UPDATE wp_posts SET post_content = REPLACE(post_content, '$STAGE_URL', '$PROD_URL'), post_excerpt = REPLACE(post_excerpt, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo "wp db query \"UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo "wp db query \"UPDATE wp_comments SET comment_content = REPLACE(comment_content, '$STAGE_URL', '$PROD_URL'), comment_author_url = REPLACE(comment_author_url, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo "wp db query \"UPDATE wp_commentmeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo "wp db query \"UPDATE wp_usermeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');\" --allow-root"
        echo ""
        echo "Or use WP-CLI search-replace:"
        echo "wp search-replace '$STAGE_URL' '$PROD_URL' --allow-root"
        echo "=========================================="
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log "Starting URL validation for WordPress production site"
    log "Stage URL: $STAGE_URL"
    log "Production URL: $PROD_URL"
    log "Production Path: $PROD_PATH"

    # Check if WP-CLI is available
    if ! command -v wp &> /dev/null; then
        error_exit "WP-CLI is not installed. Please install it first."
    fi

    # Check if production path exists
    [[ ! -d "$PROD_PATH" ]] && error_exit "Production path does not exist: $PROD_PATH"

    # Check if wp-config.php exists
    [[ ! -f "$PROD_PATH/wp-config.php" ]] && error_exit "wp-config.php not found in production: $PROD_PATH"

    # Test database connection
    cd "$PROD_PATH"
    if ! wp db check --allow-root 2>/dev/null; then
        if ! wp db query "SELECT 1;" --allow-root 2>/dev/null; then
            error_exit "Cannot connect to production database. Please check wp-config.php settings."
        fi
    fi

    # Run validation
    validate_url_replacement
}

# Run main function
main "$@"
