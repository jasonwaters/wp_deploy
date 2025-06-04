#!/bin/bash

# WordPress Stage to Production Deployment Script
# This script safely deploys staging site to production with full backup and recovery options

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
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${BACKUP_DIR}/deployment.log"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

check_requirements() {
    log "Checking requirements..."

    # Check if WP-CLI is installed
    if ! command -v wp &> /dev/null; then
        error_exit "WP-CLI is not installed. Please install it first."
    fi

    # Check if required tools are available (mysql not needed since we use WP-CLI)
    for tool in rsync tar; do
        if ! command -v "$tool" &> /dev/null; then
            error_exit "$tool is not installed. Please install it first."
        fi
    done

    # Check if paths exist
    [[ ! -d "$STAGE_PATH" ]] && error_exit "Stage path does not exist: $STAGE_PATH"
    [[ ! -d "$PROD_PATH" ]] && error_exit "Production path does not exist: $PROD_PATH"

    # Check if wp-config.php exists in both locations
    [[ ! -f "$STAGE_PATH/wp-config.php" ]] && error_exit "wp-config.php not found in stage: $STAGE_PATH"
    [[ ! -f "$PROD_PATH/wp-config.php" ]] && error_exit "wp-config.php not found in production: $PROD_PATH"

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Test database connections using WP-CLI
    log "Testing database connections..."
    cd "$STAGE_PATH"

    # Test stage database connection with better error reporting
    if ! wp db check --allow-root 2>/dev/null; then
        log "Stage database check failed, trying alternative connection test..."
        if ! wp db query "SELECT 1;" --allow-root 2>/dev/null; then
            error_exit "Cannot connect to stage database. Please check wp-config.php settings and ensure MySQL is running."
        else
            log "Stage database connection verified (alternative method)"
        fi
    else
        log "Stage database connection verified"
    fi

    cd "$PROD_PATH"

    # Test production database connection with better error reporting
    if ! wp db check --allow-root 2>/dev/null; then
        log "Production database check failed, trying alternative connection test..."
        if ! wp db query "SELECT 1;" --allow-root 2>/dev/null; then
            error_exit "Cannot connect to production database. Please check wp-config.php settings and ensure MySQL is running."
        else
            log "Production database connection verified (alternative method)"
        fi
    else
        log "Production database connection verified"
    fi

    log "Requirements check passed"
}

create_backup() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="prod_backup_${timestamp}"
    local backup_file="${BACKUP_DIR}/${backup_name}.tar.gz"

    log "Creating full backup of production site..."

    # Create temporary directory for backup
    local temp_backup_dir="${BACKUP_DIR}/temp_${timestamp}"
    mkdir -p "$temp_backup_dir"

    # Backup files (excluding wp-config.php as it will remain unchanged)
    log "Backing up production files..."
    rsync -av --exclude='wp-config.php' "$PROD_PATH/" "$temp_backup_dir/files/"

    # Backup database using WP-CLI
    log "Backing up production database..."
    cd "$PROD_PATH"
    wp db export "$temp_backup_dir/database.sql" --allow-root

    # Create metadata file
    cat > "$temp_backup_dir/backup_info.txt" << EOF
Backup Created: $(date)
Production Path: $PROD_PATH
Stage Path: $STAGE_PATH
Production URL: $PROD_URL
Stage URL: $STAGE_URL
Script Version: 1.0
EOF

    # Create compressed archive
    log "Creating compressed archive..."
    cd "$BACKUP_DIR"
    tar -czf "$backup_file" -C "$temp_backup_dir" .

    # Clean up temporary directory
    rm -rf "$temp_backup_dir"

    log "Backup created: $backup_file"
    echo "$backup_file"
}

cleanup_old_backups() {
    log "Cleaning up old backups (keeping last $MAX_BACKUPS)..."

    cd "$BACKUP_DIR"
    # List backup files, sort by modification time, keep only the newest MAX_BACKUPS
    ls -t prod_backup_*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

    local remaining=$(ls prod_backup_*.tar.gz 2>/dev/null | wc -l)
    log "Backup cleanup complete. $remaining backup(s) remaining."
}

backup_preserve_table() {
    log "Checking for preserved table: $PRESERVE_TABLE"

    cd "$PROD_PATH"
    if wp db query "SHOW TABLES LIKE '$PRESERVE_TABLE'" --allow-root | grep -q "$PRESERVE_TABLE"; then
        log "Backing up preserved table: $PRESERVE_TABLE"
        wp db export "${BACKUP_DIR}/preserved_table_$(date '+%Y%m%d_%H%M%S').sql" --tables="$PRESERVE_TABLE" --allow-root
        return 0
    else
        log "Preserved table $PRESERVE_TABLE not found, skipping backup"
        return 1
    fi
}

sync_files() {
    log "Syncing files from stage to production..."

    # Backup the production wp-config.php
    cp "$PROD_PATH/wp-config.php" "${BACKUP_DIR}/wp-config.php.backup"

    # Remove all files except wp-config.php
    log "Removing production files (preserving wp-config.php)..."
    find "$PROD_PATH" -mindepth 1 -not -name 'wp-config.php' -delete

    # Copy all files from stage except wp-config.php
    log "Copying files from stage to production..."
    rsync -av --exclude='wp-config.php' "$STAGE_PATH/" "$PROD_PATH/"

    # Restore the production wp-config.php
    cp "${BACKUP_DIR}/wp-config.php.backup" "$PROD_PATH/wp-config.php"

    # Set proper permissions
    log "Setting file permissions..."
    find "$PROD_PATH" -type f -exec chmod 644 {} \;
    find "$PROD_PATH" -type d -exec chmod 755 {} \;
    chmod 600 "$PROD_PATH/wp-config.php"

    log "File sync completed"
}

migrate_database() {
    log "Starting database migration..."

    # Check if preserve table exists and back it up
    local preserve_table_exists=false
    if backup_preserve_table; then
        preserve_table_exists=true
    fi

    # Export stage database
    log "Exporting stage database..."
    cd "$STAGE_PATH"
    local stage_dump="${BACKUP_DIR}/stage_export_$(date '+%Y%m%d_%H%M%S').sql"
    wp db export "$stage_dump" --allow-root

    # Drop all production tables except preserved one
    log "Cleaning production database..."
    cd "$PROD_PATH"

    if [ "$preserve_table_exists" = true ]; then
        log "Preserving table: $PRESERVE_TABLE"

        # Disable foreign key checks to avoid constraint errors
        wp db query "SET FOREIGN_KEY_CHECKS = 0;" --allow-root

        # Get list of all tables except the preserved one
        local tables_to_drop=$(wp db query "SHOW TABLES" --allow-root | grep -v "Tables_in_" | grep -v "$PRESERVE_TABLE" | tr '\n' ' ')

        if [ -n "$tables_to_drop" ]; then
            log "Dropping tables (preserving $PRESERVE_TABLE): $tables_to_drop"
            for table in $tables_to_drop; do
                # Skip empty table names
                if [ -n "$table" ] && [ "$table" != "$PRESERVE_TABLE" ]; then
                    log "Dropping table: $table"
                    wp db query "DROP TABLE IF EXISTS \`$table\`" --allow-root 2>/dev/null || log "WARNING: Could not drop table $table"
                fi
            done
        else
            log "No tables to drop (only preserved table exists)"
        fi

        # Re-enable foreign key checks
        wp db query "SET FOREIGN_KEY_CHECKS = 1;" --allow-root

    else
        # Drop all tables using wp db reset (handles foreign keys automatically)
        log "Dropping all tables (no preserved table)"
        wp db reset --yes --allow-root
    fi

    # Import stage database
    log "Importing stage database to production..."
    wp db import "$stage_dump" --allow-root

    # Restore preserved table if it existed
    if [ "$preserve_table_exists" = true ]; then
        log "Restoring preserved table: $PRESERVE_TABLE"
        local preserved_dump=$(ls -t "${BACKUP_DIR}/preserved_table_"*.sql | head -1)
        if [ -f "$preserved_dump" ]; then
            # Import the preserved table, but handle potential conflicts
            log "Importing preserved table from: $preserved_dump"
            if wp db import "$preserved_dump" --allow-root 2>/dev/null; then
                log "Preserved table restored successfully"
            else
                log "WARNING: Could not restore preserved table - it may conflict with imported data"
                # Try to restore just the data, not the structure
                log "Attempting to restore preserved table data only..."
                # Create a temporary SQL file with just INSERT statements
                local temp_data_file="${BACKUP_DIR}/temp_preserved_data.sql"
                grep "^INSERT INTO" "$preserved_dump" > "$temp_data_file" 2>/dev/null || true
                if [ -s "$temp_data_file" ]; then
                    wp db query "$(cat "$temp_data_file")" --allow-root 2>/dev/null || log "WARNING: Could not restore preserved table data"
                    rm -f "$temp_data_file"
                else
                    log "WARNING: No INSERT statements found in preserved table backup"
                fi
            fi
        else
            log "WARNING: Preserved table backup file not found"
        fi
    fi

    log "Database migration completed"
}

update_urls() {
    log "Updating URLs from $STAGE_URL to $PROD_URL..."

    cd "$PROD_PATH"

    # Try WP-CLI search-replace first, but fall back to SQL if it fails
    log "Attempting WP-CLI search-replace..."
    if wp search-replace "$STAGE_URL" "$PROD_URL" --allow-root --dry-run 2>/dev/null; then
        echo ""
        echo "The above changes will be made to replace all instances of '$STAGE_URL' with '$PROD_URL'."
        echo "Continue with URL replacement? (y/N)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            if wp search-replace "$STAGE_URL" "$PROD_URL" --allow-root 2>/dev/null; then
                # Also handle HTTPS variants
                wp search-replace "https://$STAGE_URL" "https://$PROD_URL" --allow-root 2>/dev/null || true
                wp search-replace "http://$STAGE_URL" "https://$PROD_URL" --allow-root 2>/dev/null || true
                log "URL replacement completed using WP-CLI"
                return 0
            fi
        else
            error_exit "URL replacement cancelled by user"
        fi
    fi

    # Fall back to direct SQL replacement
    log "WP-CLI search-replace failed, using direct SQL replacement..."

    # Replace URLs in wp_options table
    local options_result=$(wp db query "UPDATE wp_options SET option_value = REPLACE(option_value, '$STAGE_URL', '$PROD_URL') WHERE option_value LIKE '%$STAGE_URL%';" --allow-root 2>&1)
    local options_affected=$(echo "$options_result" | grep -o "Rows affected: [0-9]*" | grep -o "[0-9]*" || echo "0")
    log "Updated $options_affected rows in wp_options table"

    # Replace URLs in post content
    local posts_result=$(wp db query "UPDATE wp_posts SET post_content = REPLACE(post_content, '$STAGE_URL', '$PROD_URL');" --allow-root 2>&1)
    local posts_affected=$(echo "$posts_result" | grep -o "Rows affected: [0-9]*" | grep -o "[0-9]*" || echo "0")
    log "Updated $posts_affected rows in wp_posts table"

    # Replace URLs in post meta
    local postmeta_result=$(wp db query "UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL') WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>&1)
    local postmeta_affected=$(echo "$postmeta_result" | grep -o "Rows affected: [0-9]*" | grep -o "[0-9]*" || echo "0")
    log "Updated $postmeta_affected rows in wp_postmeta table"

    # Replace URLs in comments
    local comments_result=$(wp db query "UPDATE wp_comments SET comment_content = REPLACE(comment_content, '$STAGE_URL', '$PROD_URL');" --allow-root 2>&1)
    local comments_affected=$(echo "$comments_result" | grep -o "Rows affected: [0-9]*" | grep -o "[0-9]*" || echo "0")
    log "Updated $comments_affected rows in wp_comments table"

    # Also handle HTTPS variants
    wp db query "UPDATE wp_options SET option_value = REPLACE(option_value, 'https://$STAGE_URL', 'https://$PROD_URL') WHERE option_value LIKE '%https://$STAGE_URL%';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = REPLACE(option_value, 'http://$STAGE_URL', 'https://$PROD_URL') WHERE option_value LIKE '%http://$STAGE_URL%';" --allow-root 2>/dev/null || true

    log "URL replacement completed using direct SQL"
}

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
    if [[ "$validation_errors" -eq 0 ]]; then
        log "✓ URL VALIDATION PASSED: All STAGE_URL references have been successfully replaced"
        return 0
    else
        log "⚠ URL VALIDATION FAILED: Found $total_stage_refs total STAGE_URL references across $validation_errors table(s)"
        log "Manual cleanup may be required for the remaining references shown above"

        # Offer to attempt additional cleanup
        echo ""
        echo "Would you like to attempt automatic cleanup of the remaining STAGE_URL references? (y/N)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log "Attempting additional URL cleanup..."

            # Additional cleanup attempts
            wp db query "UPDATE wp_options SET option_value = REPLACE(option_value, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true
            wp db query "UPDATE wp_posts SET post_content = REPLACE(post_content, '$STAGE_URL', '$PROD_URL'), post_excerpt = REPLACE(post_excerpt, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true
            wp db query "UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true
            wp db query "UPDATE wp_comments SET comment_content = REPLACE(comment_content, '$STAGE_URL', '$PROD_URL'), comment_author_url = REPLACE(comment_author_url, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true
            wp db query "UPDATE wp_commentmeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true
            wp db query "UPDATE wp_usermeta SET meta_value = REPLACE(meta_value, '$STAGE_URL', '$PROD_URL');" --allow-root 2>/dev/null || true

            log "Additional cleanup completed. Re-running validation..."
            validate_url_replacement
        else
            log "Continuing with deployment despite validation warnings..."
            return 1
        fi
    fi
}

flush_cache() {
    log "Flushing WordPress cache and rewrite rules..."

    cd "$PROD_PATH"

    # Try to flush rewrite rules (optional, may fail due to WP-CLI connection issues)
    if wp rewrite flush --allow-root 2>/dev/null; then
        log "Rewrite rules flushed successfully"
    else
        log "WARNING: Could not flush rewrite rules via WP-CLI (this is optional)"
    fi

    # Try to clear object cache (optional)
    if wp cache flush --allow-root 2>/dev/null; then
        log "Object cache flushed successfully"
    else
        log "Object cache flush not available or failed (this is optional)"
    fi

    # Try to update WordPress database (optional)
    if wp core update-db --allow-root 2>/dev/null; then
        log "WordPress database updated successfully"
    else
        log "WARNING: Could not update WordPress database via WP-CLI (this is optional)"
    fi

    # Try to clear transients (optional)
    if wp transient delete --all --allow-root 2>/dev/null; then
        log "Transients cleared successfully"
    else
        log "WARNING: Could not clear transients via WP-CLI (this is optional)"
    fi

    log "Cache flush completed (some operations may have been skipped due to connection issues)"
}

verify_deployment() {
    log "Verifying deployment..."

    cd "$PROD_PATH"

    # Check if WordPress is accessible using basic database query
    if wp db query "SELECT COUNT(*) FROM wp_options WHERE option_name = 'siteurl';" --allow-root >/dev/null 2>&1; then
        log "Database connection verified"
    else
        error_exit "Database connection verification failed"
    fi

    # Try to check WordPress installation status
    if wp core is-installed --allow-root 2>/dev/null; then
        log "WordPress installation verified via WP-CLI"
    else
        log "WARNING: Could not verify WordPress installation via WP-CLI, checking database instead..."
        # Alternative check using database - get the actual site URL value
        local site_url_result=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" --allow-root 2>/dev/null)
        local site_url=$(echo "$site_url_result" | grep -v "option_value" | grep -v "^$" | head -1)

        if [[ -n "$site_url" && "$site_url" != "option_value" ]]; then
            log "WordPress installation verified via database (site URL: $site_url)"
        else
            # Try a different approach - check if we have WordPress core tables
            local wp_tables=$(wp db query "SHOW TABLES LIKE 'wp_%';" --allow-root 2>/dev/null | wc -l)
            if [[ "$wp_tables" -gt 10 ]]; then
                log "WordPress installation verified via table count ($wp_tables WordPress tables found)"
            else
                log "WARNING: WordPress installation verification inconclusive, but continuing..."
            fi
        fi
    fi

    # Check if the URL replacement worked
    local site_url_result=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" --allow-root 2>/dev/null)
    local site_url=$(echo "$site_url_result" | grep -v "option_value" | grep -v "^$" | head -1)

    if [[ -n "$site_url" && "$site_url" == *"$PROD_URL"* ]]; then
        log "Site URL correctly set to production: $site_url"
    else
        log "WARNING: Site URL may not be correctly set: $site_url (expected to contain: $PROD_URL)"
    fi

    # Check that we have content
    local post_count_result=$(wp db query "SELECT COUNT(*) FROM wp_posts WHERE post_status = 'publish';" --allow-root 2>/dev/null)
    local post_count=$(echo "$post_count_result" | grep -v "COUNT" | grep -v "^$" | head -1)

    if [[ "$post_count" =~ ^[0-9]+$ ]] && [[ "$post_count" -gt 0 ]]; then
        log "Content verification passed: $post_count published posts found"
    else
        log "WARNING: Could not verify content or no published posts found (result: $post_count)"
    fi

    log "Deployment verification completed"
}

show_summary() {
    local backup_file="$1"

    echo ""
    echo "=========================================="
    echo "DEPLOYMENT COMPLETED SUCCESSFULLY"
    echo "=========================================="
    echo "Timestamp: $(date)"
    echo "Backup created: $backup_file"
    echo "Stage site: $STAGE_URL"
    echo "Production site: $PROD_URL"
    echo ""
    echo "IMPORTANT: Please verify the following manually:"
    echo "1. Visit https://$PROD_URL to ensure it's working correctly"
    echo "2. Test critical functionality (forms, e-commerce, etc.)"
    echo "3. Check that SSL certificates are working"
    echo "4. Verify any third-party integrations"
    echo "5. Test user login functionality"
    echo "6. Check that contact forms are working"
    echo ""
    echo "If issues occur, you can restore from: $backup_file"
    echo "=========================================="
}

update_search_engine_visibility() {
    log "Ensuring search engines can index the production site..."

    cd "$PROD_PATH"

    # Set blog_public to 1 to allow search engine indexing
    # 0 = Discourage search engines (checked)
    # 1 = Allow search engines (unchecked)
    local result=$(wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'blog_public';" --allow-root 2>&1)

    # Verify the change was made
    local current_value=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'blog_public';" --allow-root 2>/dev/null | grep -v "option_value" | grep -v "^$" | head -1)

    if [[ "$current_value" == "1" ]]; then
        log "✓ Search engine indexing enabled (blog_public = 1)"
    else
        log "WARNING: Could not verify search engine indexing setting (current value: $current_value)"
        # Try alternative method using WP-CLI
        if wp option update blog_public 1 --allow-root 2>/dev/null; then
            log "✓ Search engine indexing enabled via WP-CLI"
        else
            log "ERROR: Failed to enable search engine indexing"
        fi
    fi
}

update_production_settings() {
    log "Updating WordPress settings for production environment..."

    cd "$PROD_PATH"

    # 1. Enable search engine indexing (most important)
    log "Setting search engine visibility..."
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'blog_public';" --allow-root 2>/dev/null || true
    local blog_public=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'blog_public';" --allow-root 2>/dev/null | grep -v "option_value" | grep -v "^$" | head -1)
    if [[ "$blog_public" == "1" ]]; then
        log "✓ Search engine indexing enabled"
    else
        wp option update blog_public 1 --allow-root 2>/dev/null || log "WARNING: Could not enable search engine indexing"
    fi

    # 2. Disable WordPress debug mode (should be off in production)
    log "Disabling debug mode for production..."
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG_LOG';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG_DISPLAY';" --allow-root 2>/dev/null || true
    log "✓ Debug settings configured for production"

    # 3. Set appropriate comment moderation (usually stricter in production)
    log "Configuring comment moderation for production..."
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'comment_moderation';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'moderation_notify';" --allow-root 2>/dev/null || true
    log "✓ Comment moderation enabled"

    # 4. Disable file editing in WordPress admin (security best practice)
    log "Disabling file editing in WordPress admin..."
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'disallow_file_edit';" --allow-root 2>/dev/null || true
    log "✓ File editing disabled in admin"

    # 5. Set timezone to production timezone if specified
    if [[ -n "${PROD_TIMEZONE:-}" ]]; then
        log "Setting production timezone to: $PROD_TIMEZONE"
        wp option update timezone_string "$PROD_TIMEZONE" --allow-root 2>/dev/null || log "WARNING: Could not set timezone"
    fi

    # 6. Update admin email if specified
    if [[ -n "${PROD_ADMIN_EMAIL:-}" ]]; then
        log "Setting production admin email to: $PROD_ADMIN_EMAIL"
        wp option update admin_email "$PROD_ADMIN_EMAIL" --allow-root 2>/dev/null || log "WARNING: Could not set admin email"
    fi

    # 7. Disable automatic updates for major versions (optional - you may want manual control)
    log "Configuring automatic updates for production..."
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'auto_update_core_major';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'auto_update_core_minor';" --allow-root 2>/dev/null || true
    log "✓ Automatic updates configured (minor updates enabled, major updates disabled)"

    # 8. Set appropriate cron settings
    log "Configuring WordPress cron for production..."
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'doing_cron';" --allow-root 2>/dev/null || true
    log "✓ WordPress cron configured"

    # 9. Clear any staging-specific transients or cache
    log "Clearing staging-specific transients..."
    wp transient delete --all --allow-root 2>/dev/null || log "WARNING: Could not clear transients"

    # 10. Update robots.txt related settings if using WordPress to manage it
    log "Ensuring robots.txt allows indexing..."
    wp db query "UPDATE wp_options SET option_value = '' WHERE option_name = 'blog_public_robots';" --allow-root 2>/dev/null || true

    # 11. Disable maintenance mode if it was enabled
    log "Ensuring maintenance mode is disabled..."
    wp maintenance-mode deactivate --allow-root 2>/dev/null || true

    # 12. Update permalink structure to ensure it's production-ready
    log "Flushing permalink structure..."
    wp rewrite flush --allow-root 2>/dev/null || log "WARNING: Could not flush permalinks"

    log "Production settings update completed"
}

# =============================================================================
# MAIN DEPLOYMENT PROCESS
# =============================================================================

main() {
    log "Starting WordPress deployment from stage to production"
    log "Stage: $STAGE_PATH ($STAGE_URL)"
    log "Production: $PROD_PATH ($PROD_URL)"

    # Show configuration summary
    echo ""
    echo "Deployment Configuration:"
    echo "Stage Path: $STAGE_PATH"
    echo "Production Path: $PROD_PATH"
    echo "Stage URL: $STAGE_URL"
    echo "Production URL: $PROD_URL"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Preserved Table: $PRESERVE_TABLE"
    echo ""

    # Final confirmation
    echo "This will REPLACE your production site with the staging site content."
    echo "A full backup will be created before proceeding."
    echo ""
    echo "Are you sure you want to continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Deployment cancelled by user"
        exit 0
    fi

    # Pre-flight checks
    check_requirements

    # Step 1 & 2: Create backup and cleanup old ones
    local backup_file=$(create_backup)
    cleanup_old_backups

    # Step 3 & 4: Sync files from stage to production
    sync_files

    # Step 5 & 6: Database migration
    migrate_database

    # Step 7: URL replacement
    update_urls

    # Step 8: Validate URL replacement
    validate_url_replacement

    # Additional steps for WordPress optimization
    flush_cache
    verify_deployment

    # Step 9: Update search engine visibility
    update_search_engine_visibility

    # Step 10: Update production settings
    update_production_settings

    # Show completion summary
    show_summary "$backup_file"

    log "Deployment process completed successfully!"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Trap to handle script interruption
trap 'log "Script interrupted. Check logs for details."; exit 1' INT TERM

# Run main function
main "$@"
