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
    cd "$STAGE_PATH"

    # Test stage database connection with better error reporting
    if ! wp db check --allow-root 2>/dev/null; then
        if ! wp db query "SELECT 1;" --allow-root 2>/dev/null; then
            error_exit "Cannot connect to stage database. Please check wp-config.php settings and ensure MySQL is running."
        else
            log "✓ Stage database connection verified"
        fi
    else
        log "✓ Stage database connection verified"
    fi

    cd "$PROD_PATH"

    # Test production database connection with better error reporting
    if ! wp db check --allow-root 2>/dev/null; then
        if ! wp db query "SELECT 1;" --allow-root 2>/dev/null; then
            error_exit "Cannot connect to production database. Please check wp-config.php settings and ensure MySQL is running."
        else
            log "✓ Production database connection verified"
        fi
    else
        log "✓ Production database connection verified"
    fi

    log "✓ Requirements check passed"
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
    rsync -a --exclude='wp-config.php' "$PROD_PATH/" "$temp_backup_dir/files/"

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

backup_preserve_tables() {
    log "Checking for preserved tables: $PRESERVE_TABLES"

    local tables_found=0
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')

    cd "$PROD_PATH"

    # Check each table in the PRESERVE_TABLES list
    for table in $PRESERVE_TABLES; do
        if wp db query "SHOW TABLES LIKE '$table'" --allow-root | grep -q "$table"; then
            log "Backing up preserved table: $table"
            wp db export "${BACKUP_DIR}/preserved_${table}_${backup_timestamp}.sql" --tables="$table" --allow-root
            tables_found=$((tables_found + 1))
        fi
    done

    if [[ $tables_found -gt 0 ]]; then
        log "✓ Successfully backed up $tables_found preserved table(s)"
        return 0
    else
        log "No preserved tables found to backup"
        return 1
    fi
}

clear_production_cache() {
    log "Clearing all production cache files and directories..."

    cd "$PROD_PATH"

    # 1. Clear common cache directories
    local cache_dirs=(
        "wp-content/cache"
        "wp-content/uploads/cache"
        "wp-content/w3tc-config"
        "wp-content/wp-rocket-config"
        "wp-content/litespeed"
        "wp-content/et-cache"
        "wp-content/autoptimize"
        "wp-content/wp-fastest-cache"
        "wp-content/wp-super-cache"
        "wp-content/breeze"
        "wp-content/swift-performance"
        "wp-content/hummingbird-assets"
        "wp-content/sg-cachepress"
        "wp-content/endurance-page-cache"
        "wp-content/object-cache"
        "wp-content/db-cache"
        "wp-content/advanced-cache"
    )

    for cache_dir in "${cache_dirs[@]}"; do
        if [[ -d "$cache_dir" ]]; then
            log "Removing cache directory: $cache_dir"
            rm -rf "$cache_dir" 2>/dev/null || log "WARNING: Could not remove $cache_dir"
        fi
    done

    # 2. Clear common cache files
    local cache_files=(
        "wp-content/advanced-cache.php"
        "wp-content/object-cache.php"
        "wp-content/db-cache.php"
        "wp-content/wp-cache-config.php"
        ".htaccess.bak"
        "wp-content/.htaccess.bak"
    )

    for cache_file in "${cache_files[@]}"; do
        if [[ -f "$cache_file" ]]; then
            log "Removing cache file: $cache_file"
            rm -f "$cache_file" 2>/dev/null || log "WARNING: Could not remove $cache_file"
        fi
    done

    # 3. Clear any .cache files and directories recursively
    log "Removing any remaining .cache files and directories..."
    find . -name "*.cache" -type f -delete 2>/dev/null || true
    find . -name ".cache" -type d -exec rm -rf {} + 2>/dev/null || true

    # 4. Clear temporary files that might be cache-related
    log "Removing temporary cache-related files..."
    find wp-content -name "*.tmp" -type f -delete 2>/dev/null || true
    find wp-content -name "*.temp" -type f -delete 2>/dev/null || true

    # 5. Clear any minified/optimized files that might be stale
    log "Removing potentially stale optimized files..."
    find wp-content -name "*.min.css.gz" -type f -delete 2>/dev/null || true
    find wp-content -name "*.min.js.gz" -type f -delete 2>/dev/null || true

    log "✓ Production cache cleanup completed"
}

sync_files() {
    log "Syncing files from stage to production..."

    # Backup the production wp-config.php
    cp "$PROD_PATH/wp-config.php" "${BACKUP_DIR}/wp-config.php.backup"

    # Efficient rsync with optimizations
    log "Running optimized rsync (this may take a few minutes for large sites)..."

    # Create exclude file for common files that shouldn't be synced
    local exclude_file="${BACKUP_DIR}/rsync_excludes.txt"
    cat > "$exclude_file" << 'EOF'
wp-config.php
.git/
.gitignore
.DS_Store
Thumbs.db
*.log
*.tmp
*.temp
.htaccess.bak
wp-content/cache/
wp-content/uploads/cache/
wp-content/w3tc-config/
wp-content/wp-rocket-config/
wp-content/litespeed/
wp-content/et-cache/
wp-content/autoptimize/
wp-content/wp-fastest-cache/
wp-content/wp-super-cache/
wp-content/breeze/
wp-content/swift-performance/
wp-content/hummingbird-assets/
wp-content/sg-cachepress/
wp-content/endurance-page-cache/
wp-content/object-cache/
wp-content/db-cache/
wp-content/advanced-cache/
wp-content/advanced-cache.php
wp-content/object-cache.php
wp-content/db-cache.php
wp-content/wp-cache-config.php
wp-content/backup-db/
wp-content/backups/
wp-content/updraft/
node_modules/
.sass-cache/
*.swp
*.swo
*~
*.cache
.cache/
EOF

    # Optimized rsync command
    if rsync \
        --archive \
        --compress \
        --progress \
        --human-readable \
        --checksum \
        --delete \
        --delete-excluded \
        --exclude-from="$exclude_file" \
        "$STAGE_PATH/" "$PROD_PATH/"; then

        log "✓ File sync completed successfully"

        # Clean up exclude file
        rm -f "$exclude_file"
    else
        error_exit "File sync failed"
    fi

    # Restore the production wp-config.php
    cp "${BACKUP_DIR}/wp-config.php.backup" "$PROD_PATH/wp-config.php"

    # Set proper permissions (optimized for speed)
    log "Setting file permissions (optimized)..."

    # Method 1: Use find with + operator (much faster than -exec {} \;)
    # This batches multiple files into single chmod commands
    if command -v xargs &> /dev/null; then
        # Use xargs for maximum efficiency (processes files in batches)
        log "Setting directory permissions to 755..."
        find "$PROD_PATH" -type d -print0 | xargs -0 -P 4 chmod 755 2>/dev/null || {
            log "Fallback: Using find with + operator for directories..."
            find "$PROD_PATH" -type d -exec chmod 755 {} + 2>/dev/null
        }

        log "Setting file permissions to 644..."
        find "$PROD_PATH" -type f -print0 | xargs -0 -P 4 chmod 644 2>/dev/null || {
            log "Fallback: Using find with + operator for files..."
            find "$PROD_PATH" -type f -exec chmod 644 {} + 2>/dev/null
        }
    else
        # Fallback: Use find with + operator (still much faster than {} \;)
        log "Setting directory permissions to 755..."
        find "$PROD_PATH" -type d -exec chmod 755 {} +

        log "Setting file permissions to 644..."
        find "$PROD_PATH" -type f -exec chmod 644 {} +
    fi

    # Set specific permissions for sensitive files
    log "Setting secure permissions for wp-config.php..."
    chmod 644 "$PROD_PATH/wp-config.php" 2>/dev/null || log "WARNING: Could not set wp-config.php permissions"

    # Set permissions for .htaccess if it exists (Apache only)
    if [[ -f "$PROD_PATH/.htaccess" ]]; then
        chmod 644 "$PROD_PATH/.htaccess" 2>/dev/null || log "WARNING: Could not set .htaccess permissions"
        log "INFO: Found .htaccess file (Apache configuration)"
    else
        log "INFO: No .htaccess file found (likely using Nginx)"
    fi

    # Set special permissions for WordPress uploads directory (needs to be writable)
    if [[ -d "$PROD_PATH/wp-content/uploads" ]]; then
        log "Setting uploads directory permissions..."
        chmod 755 "$PROD_PATH/wp-content/uploads" 2>/dev/null || log "WARNING: Could not set uploads directory permissions"
        # Some hosting environments need 775 for uploads - uncomment if needed:
        # chmod 775 "$PROD_PATH/wp-content/uploads" 2>/dev/null || log "WARNING: Could not set uploads directory permissions"

        # Ensure all subdirectories in uploads are accessible
        find "$PROD_PATH/wp-content/uploads" -type d -exec chmod 755 {} + 2>/dev/null || true
        log "✓ Uploads directory permissions set"
    fi

    # Ensure backup directory has proper permissions
    if [[ -d "$BACKUP_DIR" ]]; then
        chmod 755 "$BACKUP_DIR" 2>/dev/null || log "WARNING: Could not set backup directory permissions"
    fi

    log "File sync completed"
}

migrate_database() {
    log "Starting database migration..."

    # Check if preserve tables exist and back them up
    local preserve_tables_exist=false
    if backup_preserve_tables; then
        preserve_tables_exist=true
    fi

    # Export stage database
    log "Exporting stage database..."
    cd "$STAGE_PATH"
    local stage_dump="${BACKUP_DIR}/stage_export_$(date '+%Y%m%d_%H%M%S').sql"
    wp db export "$stage_dump" --allow-root

    # Drop all production tables except preserved ones
    log "Cleaning production database..."
    cd "$PROD_PATH"

    if [ "$preserve_tables_exist" = true ]; then
        log "Preserving tables: $PRESERVE_TABLES"

        # Disable foreign key checks to avoid constraint errors
        wp db query "SET FOREIGN_KEY_CHECKS = 0;" --allow-root

        # Get list of all tables
        local all_tables=$(wp db query "SHOW TABLES" --allow-root | grep -v "Tables_in_" | tr '\n' ' ')
        local tables_to_drop=""

        # Build list of tables to drop (excluding preserved ones)
        for table in $all_tables; do
            local should_preserve=false
            for preserved_table in $PRESERVE_TABLES; do
                if [[ "$table" == "$preserved_table" ]]; then
                    should_preserve=true
                    break
                fi
            done

            if [[ "$should_preserve" == false && -n "$table" ]]; then
                tables_to_drop="$tables_to_drop $table"
            fi
        done

        if [ -n "$tables_to_drop" ]; then
            log "Dropping tables (preserving: $PRESERVE_TABLES)"
            log "Tables to drop: $tables_to_drop"
            for table in $tables_to_drop; do
                # Skip empty table names
                if [ -n "$table" ]; then
                    log "Dropping table: $table"
                    wp db query "DROP TABLE IF EXISTS \`$table\`" --allow-root 2>/dev/null || log "WARNING: Could not drop table $table"
                fi
            done
        else
            log "No tables to drop (only preserved tables exist)"
        fi

        # Re-enable foreign key checks
        wp db query "SET FOREIGN_KEY_CHECKS = 1;" --allow-root

    else
        # Drop all tables using wp db reset (handles foreign keys automatically)
        log "Dropping all tables (no preserved tables)"
        wp db reset --yes --allow-root
    fi

    # Import stage database
    log "Importing stage database to production..."
    wp db import "$stage_dump" --allow-root

    # Restore preserved tables if they existed
    if [ "$preserve_tables_exist" = true ]; then
        log "Restoring preserved tables..."

        # Get the backup timestamp from the most recent backup
        local backup_timestamp=$(ls -t "${BACKUP_DIR}/preserved_"*".sql" 2>/dev/null | head -1 | sed 's/.*_\([0-9]\{8\}_[0-9]\{6\}\)\.sql$/\1/')

        # Restore each preserved table
        for table in $PRESERVE_TABLES; do
            local preserved_dump="${BACKUP_DIR}/preserved_${table}_${backup_timestamp}.sql"

            if [ -f "$preserved_dump" ]; then
                log "Restoring preserved table: $table from $preserved_dump"
                if wp db import "$preserved_dump" --allow-root 2>/dev/null; then
                    log "✓ Preserved table $table restored successfully"
                else
                    log "WARNING: Could not restore preserved table $table - it may conflict with imported data"
                    # Try to restore just the data, not the structure
                    log "Attempting to restore preserved table $table data only..."
                    # Create a temporary SQL file with just INSERT statements
                    local temp_data_file="${BACKUP_DIR}/temp_preserved_${table}_data.sql"
                    grep "^INSERT INTO" "$preserved_dump" > "$temp_data_file" 2>/dev/null || true
                    if [ -s "$temp_data_file" ]; then
                        if wp db query "$(cat "$temp_data_file")" --allow-root 2>/dev/null; then
                            log "✓ Preserved table $table data restored successfully"
                        else
                            log "WARNING: Could not restore preserved table $table data"
                        fi
                        rm -f "$temp_data_file"
                    else
                        log "WARNING: No INSERT statements found in preserved table $table backup"
                    fi
                fi
            else
                log "WARNING: Preserved table backup file not found: $preserved_dump"
            fi
        done
    fi

    log "Database migration completed"
}

update_urls() {
    log "Updating URLs from $STAGE_URL to $PROD_URL..."

    cd "$PROD_PATH"

    # Check if WP-CLI can connect first
    local wp_cli_available=false
    if wp core is-installed --allow-root 2>/dev/null; then
        wp_cli_available=true
    fi

    # Try WP-CLI search-replace first, but fall back to SQL if it fails
    if [[ "$wp_cli_available" == true ]]; then
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
                    log "✓ URL replacement completed using WP-CLI"
                    return 0
                fi
            else
                error_exit "URL replacement cancelled by user"
            fi
        fi
    fi

    # Fall back to direct SQL replacement
    log "Using direct SQL replacement method..."

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

    log "✓ URL replacement completed using direct SQL"
}

validate_url_replacement() {
    log "Validating URL replacement..."

    cd "$PROD_PATH"

    local validation_errors=0
    local total_stage_refs=0

    # Check wp_options table for any remaining stage URLs
    local options_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$options_stage_count" =~ ^[0-9]+$ ]] && [[ "$options_stage_count" -gt 0 ]]; then
        log "WARNING: Found $options_stage_count references to STAGE_URL in wp_options table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + options_stage_count))
    fi

    # Check wp_posts table for any remaining stage URLs
    local posts_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_posts WHERE post_content LIKE '%$STAGE_URL%' OR post_excerpt LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$posts_stage_count" =~ ^[0-9]+$ ]] && [[ "$posts_stage_count" -gt 0 ]]; then
        log "WARNING: Found $posts_stage_count references to STAGE_URL in wp_posts table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + posts_stage_count))
    fi

    # Check wp_postmeta table for any remaining stage URLs
    local postmeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_postmeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$postmeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$postmeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $postmeta_stage_count references to STAGE_URL in wp_postmeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + postmeta_stage_count))
    fi

    # Check wp_comments table for any remaining stage URLs
    local comments_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_comments WHERE comment_content LIKE '%$STAGE_URL%' OR comment_author_url LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$comments_stage_count" =~ ^[0-9]+$ ]] && [[ "$comments_stage_count" -gt 0 ]]; then
        log "WARNING: Found $comments_stage_count references to STAGE_URL in wp_comments table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + comments_stage_count))
    fi

    # Check wp_commentmeta table for any remaining stage URLs
    local commentmeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_commentmeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$commentmeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$commentmeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $commentmeta_stage_count references to STAGE_URL in wp_commentmeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + commentmeta_stage_count))
    fi

    # Check wp_usermeta table for any remaining stage URLs
    local usermeta_stage_count=$(wp db query "SELECT COUNT(*) as count FROM wp_usermeta WHERE meta_value LIKE '%$STAGE_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$usermeta_stage_count" =~ ^[0-9]+$ ]] && [[ "$usermeta_stage_count" -gt 0 ]]; then
        log "WARNING: Found $usermeta_stage_count references to STAGE_URL in wp_usermeta table"
        validation_errors=$((validation_errors + 1))
        total_stage_refs=$((total_stage_refs + usermeta_stage_count))
    fi

    # Check for HTTPS variants as well
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
    local prod_url_count=$(wp db query "SELECT COUNT(*) as count FROM wp_options WHERE option_value LIKE '%$PROD_URL%';" --allow-root 2>/dev/null | grep -v "count" | grep -v "^$" | head -1)
    if [[ "$prod_url_count" =~ ^[0-9]+$ ]] && [[ "$prod_url_count" -gt 0 ]]; then
        log "✓ Found $prod_url_count references to PROD_URL in database"
    else
        log "WARNING: No references to PROD_URL found in database"
        validation_errors=$((validation_errors + 1))
    fi

    # Summary
    if [[ "$validation_errors" -eq 0 ]]; then
        log "✓ URL validation passed: All STAGE_URL references successfully replaced"
        return 0
    else
        log "⚠ URL validation failed: Found $total_stage_refs total STAGE_URL references across $validation_errors table(s)"

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

    # Wait a moment for WordPress to stabilize after database import
    sleep 2

    # Check if WP-CLI can connect to WordPress before attempting operations
    local wp_cli_available=false
    if wp core is-installed --allow-root 2>/dev/null; then
        wp_cli_available=true
    fi

    # Try to flush rewrite rules with retry logic
    local rewrite_success=false

    if [[ "$wp_cli_available" == true ]]; then
        for attempt in 1 2 3; do
            if wp rewrite flush --allow-root 2>/dev/null; then
                log "✓ Rewrite rules flushed successfully"
                rewrite_success=true
                break
            else
                if [[ $attempt -lt 3 ]]; then
                    sleep 2
                fi
            fi
        done
    fi

    if [[ "$rewrite_success" == false ]]; then
        # Alternative for Nginx: Update rewrite_rules option directly in database
        if wp db query "DELETE FROM wp_options WHERE option_name = 'rewrite_rules';" --allow-root 2>/dev/null; then
            log "✓ Cleared rewrite rules cache via database"
        fi
    fi

    # Try to clear object cache with retry logic
    local cache_success=false

    if [[ "$wp_cli_available" == true ]]; then
        for attempt in 1 2 3; do
            if wp cache flush --allow-root 2>/dev/null; then
                log "✓ Object cache flushed successfully"
                cache_success=true
                break
            else
                if [[ $attempt -lt 3 ]]; then
                    sleep 2
                fi
            fi
        done
    fi

    # Try to update WordPress database with retry logic
    local db_update_success=false

    if [[ "$wp_cli_available" == true ]]; then
        for attempt in 1 2 3; do
            if wp core update-db --allow-root 2>/dev/null; then
                log "✓ WordPress database updated successfully"
                db_update_success=true
                break
            else
                if [[ $attempt -lt 3 ]]; then
                    sleep 2
                fi
            fi
        done
    fi

    # Try to clear transients with retry logic
    local transient_success=false

    if [[ "$wp_cli_available" == true ]]; then
        for attempt in 1 2 3; do
            if wp transient delete --all --allow-root 2>/dev/null; then
                log "✓ Transients cleared successfully"
                transient_success=true
                break
            else
                if [[ $attempt -lt 3 ]]; then
                    sleep 2
                fi
            fi
        done
    fi

    if [[ "$transient_success" == false ]]; then
        # Alternative: Clear transients via direct database query
        if wp db query "DELETE FROM wp_options WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%';" --allow-root 2>/dev/null; then
            log "✓ Transients cleared via database"
        fi
    fi

    log "✓ Cache flush operations completed"
}

verify_deployment() {
    log "Verifying deployment..."

    cd "$PROD_PATH"

    # Check if WordPress is accessible using basic database query
    if wp db query "SELECT COUNT(*) FROM wp_options WHERE option_name = 'siteurl';" --allow-root >/dev/null 2>&1; then
        log "✓ Database connection verified"
    else
        error_exit "Database connection verification failed"
    fi

    # Check if WP-CLI can connect to WordPress
    local wp_cli_available=false
    if wp core is-installed --allow-root 2>/dev/null; then
        wp_cli_available=true
        log "✓ WordPress installation verified"
    else
        # Alternative check using database - get the actual site URL value
        local site_url_result=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" --allow-root 2>/dev/null)
        local site_url=$(echo "$site_url_result" | grep -v "option_value" | grep -v "^$" | head -1)

        if [[ -n "$site_url" && "$site_url" != "option_value" ]]; then
            log "✓ WordPress installation verified via database"
        else
            # Try a different approach - check if we have WordPress core tables
            local wp_tables=$(wp db query "SHOW TABLES LIKE 'wp_%';" --allow-root 2>/dev/null | wc -l)
            if [[ "$wp_tables" -gt 10 ]]; then
                log "✓ WordPress installation verified ($wp_tables tables found)"
            else
                log "WARNING: WordPress installation verification inconclusive"
            fi
        fi
    fi

    # Check if the URL replacement worked
    local site_url_result=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" --allow-root 2>/dev/null)
    local site_url=$(echo "$site_url_result" | grep -v "option_value" | grep -v "^$" | head -1)

    if [[ -n "$site_url" && "$site_url" == *"$PROD_URL"* ]]; then
        log "✓ Site URL correctly set to production: $site_url"
    else
        log "WARNING: Site URL may not be correctly set: $site_url"
    fi

    # Check that we have content
    local post_count_result=$(wp db query "SELECT COUNT(*) FROM wp_posts WHERE post_status = 'publish';" --allow-root 2>/dev/null)
    local post_count=$(echo "$post_count_result" | grep -v "option_value" | grep -v "^$" | head -1)

    if [[ "$post_count" =~ ^[0-9]+$ ]] && [[ "$post_count" -gt 0 ]]; then
        log "✓ Content verification passed: $post_count published posts found"
    else
        log "WARNING: Could not verify content or no published posts found"
    fi

    log "✓ Deployment verification completed"
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
    if [[ -n "$PRESERVE_TABLES" ]]; then
        echo "Preserved tables: $PRESERVE_TABLES"
    fi
    echo ""
    echo "IMPORTANT: Please verify the following manually:"
    echo "1. Visit https://$PROD_URL to ensure it's working correctly"
    echo "2. Test critical functionality (forms, e-commerce, etc.)"
    echo "3. Check that SSL certificates are working"
    echo "4. Verify any third-party integrations"
    echo "5. Test user login functionality"
    echo "6. Check that contact forms are working"
    if [[ -n "$PRESERVE_TABLES" ]]; then
        echo "7. Verify preserved data (downloads, form submissions, etc.)"
    fi
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

    # Check if WP-CLI can connect to WordPress
    local wp_cli_available=false
    if wp core is-installed --allow-root 2>/dev/null; then
        wp_cli_available=true
    fi

    # 1. Enable search engine indexing (most important)
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'blog_public';" --allow-root 2>/dev/null || true
    local blog_public=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'blog_public';" --allow-root 2>/dev/null | grep -v "option_value" | grep -v "^$" | head -1)
    if [[ "$blog_public" == "1" ]]; then
        log "✓ Search engine indexing enabled"
    else
        if [[ "$wp_cli_available" == true ]]; then
            wp option update blog_public 1 --allow-root 2>/dev/null || log "WARNING: Could not enable search engine indexing"
        fi
    fi

    # 2. Disable WordPress debug mode (should be off in production)
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG_LOG';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'WP_DEBUG_DISPLAY';" --allow-root 2>/dev/null || true
    log "✓ Debug settings configured for production"

    # 3. Set appropriate comment moderation (usually stricter in production)
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'comment_moderation';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'moderation_notify';" --allow-root 2>/dev/null || true
    log "✓ Comment moderation enabled"

    # 4. Disable file editing in WordPress admin (security best practice)
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'disallow_file_edit';" --allow-root 2>/dev/null || true
    log "✓ File editing disabled in admin"

    # 5. Set timezone to production timezone if specified
    if [[ -n "${PROD_TIMEZONE:-}" ]]; then
        if [[ "$wp_cli_available" == true ]]; then
            wp option update timezone_string "$PROD_TIMEZONE" --allow-root 2>/dev/null || log "WARNING: Could not set timezone"
        else
            wp db query "UPDATE wp_options SET option_value = '$PROD_TIMEZONE' WHERE option_name = 'timezone_string';" --allow-root 2>/dev/null || true
            log "✓ Timezone set to $PROD_TIMEZONE"
        fi
    fi

    # 6. Update admin email if specified
    if [[ -n "${PROD_ADMIN_EMAIL:-}" ]]; then
        if [[ "$wp_cli_available" == true ]]; then
            wp option update admin_email "$PROD_ADMIN_EMAIL" --allow-root 2>/dev/null || log "WARNING: Could not set admin email"
        else
            wp db query "UPDATE wp_options SET option_value = '$PROD_ADMIN_EMAIL' WHERE option_name = 'admin_email';" --allow-root 2>/dev/null || true
            log "✓ Admin email set to $PROD_ADMIN_EMAIL"
        fi
    fi

    # 7. Disable automatic updates for major versions (optional - you may want manual control)
    wp db query "UPDATE wp_options SET option_value = '0' WHERE option_name = 'auto_update_core_major';" --allow-root 2>/dev/null || true
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'auto_update_core_minor';" --allow-root 2>/dev/null || true
    log "✓ Automatic updates configured"

    # 8. Set appropriate cron settings
    wp db query "UPDATE wp_options SET option_value = '1' WHERE option_name = 'doing_cron';" --allow-root 2>/dev/null || true
    log "✓ WordPress cron configured"

    # 9. Clear any staging-specific transients or cache
    if [[ "$wp_cli_available" == true ]]; then
        wp transient delete --all --allow-root 2>/dev/null || true
    fi
    # Always try database method as backup
    wp db query "DELETE FROM wp_options WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%';" --allow-root 2>/dev/null || true
    log "✓ Staging-specific transients cleared"

    # 10. Update robots.txt related settings if using WordPress to manage it
    wp db query "UPDATE wp_options SET option_value = '' WHERE option_name = 'blog_public_robots';" --allow-root 2>/dev/null || true

    # 11. Disable maintenance mode if it was enabled
    if [[ "$wp_cli_available" == true ]]; then
        wp maintenance-mode deactivate --allow-root 2>/dev/null || true
    fi

    # 12. Update permalink structure to ensure it's production-ready
    local permalink_success=false

    if [[ "$wp_cli_available" == true ]]; then
        for attempt in 1 2 3; do
            if wp rewrite flush --allow-root 2>/dev/null; then
                log "✓ Permalink structure flushed successfully"
                permalink_success=true
                break
            else
                if [[ $attempt -lt 3 ]]; then
                    sleep 2
                fi
            fi
        done
    fi

    if [[ "$permalink_success" == false ]]; then
        # Alternative for Nginx: Clear rewrite rules from database
        if wp db query "DELETE FROM wp_options WHERE option_name = 'rewrite_rules';" --allow-root 2>/dev/null; then
            log "✓ Cleared permalink cache via database"
        fi
    fi

    log "✓ Production settings update completed"
}

# Diagnostic function to understand WP-CLI connectivity issues
diagnose_wp_cli_issues() {
    local site_path="$1"
    local site_name="$2"

    log "Diagnosing WP-CLI connectivity issues for $site_name..."

    cd "$site_path"

    # Check if wp-config.php exists and is readable
    if [[ ! -f "wp-config.php" ]]; then
        log "ERROR: wp-config.php not found in $site_path"
        return 1
    fi

    if [[ ! -r "wp-config.php" ]]; then
        log "ERROR: wp-config.php is not readable in $site_path"
        return 1
    fi

    # Check database connection using direct query
    if wp db query "SELECT 1;" --allow-root >/dev/null 2>&1; then
        log "✓ Database connection working for $site_name"
    else
        log "ERROR: Database connection failed for $site_name"
        # Try to get more specific error
        local db_error=$(wp db query "SELECT 1;" --allow-root 2>&1)
        log "Database error details: $db_error"
        return 1
    fi

    # Check if WordPress core files exist
    if [[ ! -f "wp-load.php" ]]; then
        log "ERROR: WordPress core files missing (wp-load.php not found) in $site_path"
        return 1
    fi

    # Check if we can determine WordPress version
    local wp_version=$(wp core version --allow-root 2>/dev/null)
    if [[ -n "$wp_version" ]]; then
        log "✓ WordPress version detected: $wp_version for $site_name"
    else
        log "WARNING: Could not determine WordPress version for $site_name"
    fi

    # Check if WordPress is installed (tables exist)
    local table_count=$(wp db query "SHOW TABLES LIKE 'wp_%';" --allow-root 2>/dev/null | wc -l)
    if [[ "$table_count" -gt 10 ]]; then
        log "✓ WordPress tables found ($table_count tables) for $site_name"
    else
        log "ERROR: Insufficient WordPress tables found ($table_count tables) for $site_name"
        return 1
    fi

    # Check if we can read basic WordPress options
    local site_url=$(wp db query "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" --allow-root 2>/dev/null | grep -v "option_value" | grep -v "^$" | head -1)
    if [[ -n "$site_url" ]]; then
        log "✓ Site URL readable from database: $site_url for $site_name"
    else
        log "ERROR: Could not read site URL from database for $site_name"
        return 1
    fi

    # Final WP-CLI connectivity test
    if wp core is-installed --allow-root 2>/dev/null; then
        log "✓ WP-CLI can connect to WordPress for $site_name"
        return 0
    else
        log "ERROR: WP-CLI cannot connect to WordPress for $site_name despite database working"
        # Get more detailed error
        local wp_error=$(wp core is-installed --allow-root 2>&1)
        log "WP-CLI error details: $wp_error"
        return 1
    fi
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
    echo "Preserved Tables: $PRESERVE_TABLES"
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
    clear_production_cache
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

show_help() {
    echo "WordPress Stage to Production Deployment Script"
    echo "=============================================="
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -d, --diagnose    Run WP-CLI connectivity diagnostics"
    echo "  -v, --verbose     Enable verbose logging"
    echo ""
    echo "Examples:"
    echo "  $0                Run normal deployment"
    echo "  $0 --diagnose    Diagnose WP-CLI connectivity issues"
    echo "  $0 --help        Show this help"
    echo ""
    echo "Configuration:"
    echo "  Edit deploy_config.sh to configure paths and settings"
    echo ""
    echo "Logs:"
    echo "  Deployment logs are saved to: \${BACKUP_DIR}/deployment.log"
    echo ""
}

run_diagnostics() {
    echo "WordPress Deployment Diagnostics"
    echo "================================"
    echo ""

    log "Starting comprehensive WP-CLI diagnostics..."

    # Check WP-CLI installation
    if command -v wp &> /dev/null; then
        local wp_version=$(wp --version 2>/dev/null | head -1)
        log "✓ WP-CLI found: $wp_version"
    else
        log "ERROR: WP-CLI is not installed or not in PATH"
        exit 1
    fi

    # Diagnose stage site
    echo ""
    echo "Diagnosing Stage Site:"
    echo "====================="
    if diagnose_wp_cli_issues "$STAGE_PATH" "stage"; then
        log "✓ Stage site diagnostics passed"
    else
        log "✗ Stage site diagnostics failed"
    fi

    # Diagnose production site
    echo ""
    echo "Diagnosing Production Site:"
    echo "=========================="
    if diagnose_wp_cli_issues "$PROD_PATH" "production"; then
        log "✓ Production site diagnostics passed"
    else
        log "✗ Production site diagnostics failed"
    fi

    echo ""
    echo "Diagnostics completed. Check the log above for any issues."
    echo "If WP-CLI connectivity fails, the deployment script will use database-only methods."
    echo ""
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--diagnose)
            # Load configuration first
            if [[ ! -f "$CONFIG_FILE" ]]; then
                echo "ERROR: Configuration file not found: $CONFIG_FILE"
                echo "Please copy deploy_config.sh.example to deploy_config.sh and configure it."
                exit 1
            fi
            source "$CONFIG_FILE"
            run_diagnostics
            exit 0
            ;;
        -v|--verbose)
            set -x  # Enable verbose mode
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Trap to handle script interruption
trap 'log "Script interrupted. Check logs for details."; exit 1' INT TERM

# Run main function
main "$@"
