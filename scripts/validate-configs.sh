#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Root directory
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"

# Validation functions
validate_bundle_id_consistency() {
    echo -e "${YELLOW}Validating bundle ID consistency...${NC}"
    
    local project_bundle_id
    local plist_bundle_id
    
    project_bundle_id=$(grep "CFBundleIdentifier:" "$ROOT_DIR/agent-mac/project.yml" | awk '{print $2}' | tr -d '"')
    plist_bundle_id=$(grep -A1 "<key>CFBundleIdentifier</key>" "$ROOT_DIR/agent-mac/BlawbyAgent/Info.plist" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    
    if [[ "$project_bundle_id" == "$plist_bundle_id" ]]; then
        echo -e "${GREEN}✓ Bundle ID consistent: $project_bundle_id${NC}"
        return 0
    else
        echo -e "${RED}✗ Bundle ID mismatch:${NC}"
        echo -e "  project.yml: $project_bundle_id"
        echo -e "  Info.plist:   $plist_bundle_id"
        return 1
    fi
}

validate_sparkle_consistency() {
    echo -e "${YELLOW}Validating Sparkle consistency...${NC}"
    
    local project_feed_url
    local plist_feed_url
    local project_public_key
    local plist_public_key
    
    project_feed_url=$(grep "SUFeedURL:" "$ROOT_DIR/agent-mac/project.yml" | awk '{print $2}' | tr -d '"')
    plist_feed_url=$(grep -A1 "<key>SUFeedURL</key>" "$ROOT_DIR/agent-mac/BlawbyAgent/Info.plist" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    
    project_public_key=$(grep "SUPublicEDKey:" "$ROOT_DIR/agent-mac/project.yml" | awk '{print $2}' | tr -d '"')
    plist_public_key=$(grep -A1 "<key>SUPublicEDKey</key>" "$ROOT_DIR/agent-mac/BlawbyAgent/Info.plist" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    
    local errors=0
    
    if [[ "$project_feed_url" == "$plist_feed_url" ]]; then
        echo -e "${GREEN}✓ Sparkle feed URL consistent: $project_feed_url${NC}"
    else
        echo -e "${RED}✗ Sparkle feed URL mismatch:${NC}"
        echo -e "  project.yml: $project_feed_url"
        echo -e "  Info.plist:   $plist_feed_url"
        errors=1
    fi
    
    if [[ "$project_public_key" == "$plist_public_key" ]]; then
        echo -e "${GREEN}✓ Sparkle public key consistent${NC}"
    else
        echo -e "${RED}✗ Sparkle public key mismatch${NC}"
        echo -e "  project.yml: $project_public_key"
        echo -e "  Info.plist:   $plist_public_key"
        errors=1
    fi
    
    return $errors
}

validate_wrangler_shared_values() {
    echo -e "${YELLOW}Validating Wrangler shared values consistency...${NC}"
    
    local wrangler_files=("wrangler.toml" "wrangler.api.toml" "wrangler.jobs.toml")
    local shared_vars=("AIG_ACCOUNT_ID" "AIG_GATEWAY_ID" "OPENAI_MODEL" "OPENAI_EMBEDDING_MODEL" "ACCESS_AUTH_ENABLED" "ALLOW_API_KEY_BYPASS")
    local errors=0
    
    for var in "${shared_vars[@]}"; do
        local values=()
        local file_count=0
        
        for file in "${wrangler_files[@]}"; do
            if [[ -f "$ROOT_DIR/$file" ]]; then
                local value
                value=$(grep "^$var = " "$ROOT_DIR/$file" | cut -d'"' -f2)
                if [[ -n "$value" ]]; then
                    values+=("$file:$value")
                    ((file_count++))
                fi
            fi
        done
        
        if [[ $file_count -gt 0 ]]; then
            local first_value
            first_value=$(echo "${values[0]}" | cut -d':' -f2)
            local consistent=true
            
            for value_entry in "${values[@]}"; do
                local current_value
                current_value=$(echo "$value_entry" | cut -d':' -f2)
                if [[ "$current_value" != "$first_value" ]]; then
                    consistent=false
                    break
                fi
            done
            
            if [[ "$consistent" == true ]]; then
                echo -e "${GREEN}✓ $var consistent across $file_count files: $first_value${NC}"
            else
                echo -e "${RED}✗ $var inconsistent across files:${NC}"
                for value_entry in "${values[@]}"; do
                    echo -e "  $value_entry"
                done
                errors=1
            fi
        fi
    done
    
    return $errors
}

validate_database_consistency() {
    echo -e "${YELLOW}Validating database configuration consistency...${NC}"
    
    local wrangler_files=("wrangler.toml" "wrangler.api.toml" "wrangler.jobs.toml")
    local errors=0
    
    # Check development database consistency
    local dev_db_names=()
    local dev_db_ids=()
    
    for file in "${wrangler_files[@]}"; do
        if [[ -f "$ROOT_DIR/$file" ]]; then
            local db_name
            local db_id
            db_name=$(grep -A1 "database_name = " "$ROOT_DIR/$file" | tail -1 | cut -d'"' -f2)
            db_id=$(grep "database_id = " "$ROOT_DIR/$file" | cut -d'"' -f2)
            
            if [[ -n "$db_name" ]]; then
                dev_db_names+=("$file:$db_name")
            fi
            if [[ -n "$db_id" ]]; then
                dev_db_ids+=("$file:$db_id")
            fi
        fi
    done
    
    # Check database name consistency
    local first_db_name
    first_db_name=$(echo "${dev_db_names[0]}" | cut -d':' -f2)
    local db_names_consistent=true
    
    for db_name_entry in "${dev_db_names[@]}"; do
        local current_db_name
        current_db_name=$(echo "$db_name_entry" | cut -d':' -f2)
        if [[ "$current_db_name" != "$first_db_name" ]]; then
            db_names_consistent=false
            break
        fi
    done
    
    if [[ "$db_names_consistent" == true ]]; then
        echo -e "${GREEN}✓ Development database name consistent: $first_db_name${NC}"
    else
        echo -e "${RED}✗ Development database name inconsistent:${NC}"
        for db_name_entry in "${dev_db_names[@]}"; do
            echo -e "  $db_name_entry"
        done
        errors=1
    fi
    
    # Check database ID consistency
    local first_db_id
    first_db_id=$(echo "${dev_db_ids[0]}" | cut -d':' -f2)
    local db_ids_consistent=true
    
    for db_id_entry in "${dev_db_ids[@]}"; do
        local current_db_id
        current_db_id=$(echo "$db_id_entry" | cut -d':' -f2)
        if [[ "$current_db_id" != "$first_db_id" ]]; then
            db_ids_consistent=false
            break
        fi
    done
    
    if [[ "$db_ids_consistent" == true ]]; then
        echo -e "${GREEN}✓ Development database ID consistent${NC}"
    else
        echo -e "${RED}✗ Development database ID inconsistent:${NC}"
        for db_id_entry in "${dev_db_ids[@]}"; do
            echo -e "  $db_id_entry"
        done
        errors=1
    fi
    
    return $errors
}

validate_signing_expectations() {
    echo -e "${YELLOW}Validating signing configuration expectations...${NC}"
    
    local project_signing
    local ci_signing
    
    project_signing=$(grep "CODE_SIGN_STYLE:" "$ROOT_DIR/agent-mac/project.yml" | cut -d' ' -f2)
    
    # Check if CI workflow exists and has signing configuration
    if [[ -f "$ROOT_DIR/.github/workflows/macos-release.yml" ]]; then
        ci_signing=$(grep "CODE_SIGN_STYLE=" "$ROOT_DIR/.github/workflows/macos-release.yml" | head -1 | cut -d'=' -f2)
    fi
    
    if [[ -n "$project_signing" ]]; then
        echo -e "${GREEN}✓ Local signing style: $project_signing${NC}"
    fi
    
    if [[ -n "$ci_signing" ]]; then
        echo -e "${GREEN}✓ CI signing style: $ci_signing${NC}"
        
        if [[ "$project_signing" == "Automatic" && "$ci_signing" == "Manual" ]]; then
            echo -e "${YELLOW}⚠ Different signing styles detected (expected for local vs CI)${NC}"
        fi
    fi
    
    return 0
}

validate_config_files_exist() {
    echo -e "${YELLOW}Validating configuration files exist...${NC}"
    
    local required_files=(
        "config/shared.toml"
        "config/mac-agent.yml"
        "agent-mac/project.yml"
        "agent-mac/BlawbyAgent/Info.plist"
        "wrangler.toml"
        "wrangler.api.toml"
        "wrangler.jobs.toml"
    )
    
    local errors=0
    
    for file in "${required_files[@]}"; do
        if [[ -f "$ROOT_DIR/$file" ]]; then
            echo -e "${GREEN}✓ $file exists${NC}"
        else
            echo -e "${RED}✗ $file missing${NC}"
            errors=1
        fi
    done
    
    return $errors
}

# Main validation
main() {
    echo -e "${YELLOW}Starting configuration validation...${NC}"
    echo
    
    local total_errors=0
    
    validate_config_files_exist || ((total_errors++))
    echo
    
    validate_bundle_id_consistency || ((total_errors++))
    echo
    
    validate_sparkle_consistency || ((total_errors++))
    echo
    
    validate_wrangler_shared_values || ((total_errors++))
    echo
    
    validate_database_consistency || ((total_errors++))
    echo
    
    validate_signing_expectations || ((total_errors++))
    echo
    
    if [[ $total_errors -eq 0 ]]; then
        echo -e "${GREEN}✓ All configuration validations passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ $total_errors validation(s) failed${NC}"
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
