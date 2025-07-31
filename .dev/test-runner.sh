#!/bin/bash
set -euo pipefail

# rules_js Development Test Suite
# Runs comprehensive local testing equivalent to CI

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${SCRIPT_DIR}/test-config.json"

# Default values
MAX_PARALLEL=8
BAZEL_VERSION_FILTER=""
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --max-parallel N     Set maximum parallel jobs (default: 8)"
    echo "  --bazel-version V    Test only specific Bazel version (e.g., 6.5.0)"
    echo "  --verbose           Enable verbose output"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Test all Bazel versions"
    echo "  $0 --bazel-version=7.6.1            # Test only Bazel 7.6.1"
    echo "  $0 --max-parallel=4 --verbose       # 4 parallel jobs with verbose output"
    echo ""
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --max-parallel=*)
            MAX_PARALLEL="${1#*=}"
            shift
            ;;
        --bazel-version)
            BAZEL_VERSION_FILTER="$2"
            shift 2
            ;;
        --bazel-version=*)
            BAZEL_VERSION_FILTER="${1#*=}"
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate parallel job count
if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [ "$MAX_PARALLEL" -lt 1 ]; then
    echo -e "${RED}❌ Invalid --max-parallel value: $MAX_PARALLEL${NC}"
    exit 1
fi

# Change to repository root
cd "$ROOT_DIR"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse configuration
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq is required but not installed${NC}"
    exit 1
fi

# Get test configuration
BAZEL_VERSIONS=$(jq -r '.bazel_versions[] | @base64' "$CONFIG_FILE")
# Convert E2E tests to array
readarray -t E2E_TESTS < <(jq -r '.e2e_tests[]' "$CONFIG_FILE")

# Save original Bazel version
ORIGINAL_BAZEL_VERSION=""
if [ -f ".bazelversion" ]; then
    ORIGINAL_BAZEL_VERSION=$(cat .bazelversion)
fi

# Setup cleanup trap
cleanup() {
    echo -e "${YELLOW}🔄 Cleaning up...${NC}"
    
    # Kill any background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Restore original Bazel version
    if [ -n "$ORIGINAL_BAZEL_VERSION" ]; then
        echo "$ORIGINAL_BAZEL_VERSION" > .bazelversion
        echo -e "${BLUE}🔄 Restored Bazel version to $ORIGINAL_BAZEL_VERSION${NC}"
    fi
}

trap cleanup EXIT INT TERM

# Setup log directory
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="${SCRIPT_DIR}/logs/${TIMESTAMP}"
mkdir -p "$LOG_DIR/e2e"

# Rotate logs (keep last 2 runs)
LOGS_BASE_DIR="${SCRIPT_DIR}/logs"
if [ -d "$LOGS_BASE_DIR" ]; then
    # Move current to previous, create new current
    [ -d "$LOGS_BASE_DIR/current" ] && rm -rf "$LOGS_BASE_DIR/previous" 2>/dev/null || true
    [ -d "$LOGS_BASE_DIR/current" ] && mv "$LOGS_BASE_DIR/current" "$LOGS_BASE_DIR/previous" 2>/dev/null || true
    
    # Link new timestamp directory as current
    ln -sf "$TIMESTAMP" "$LOGS_BASE_DIR/current"
fi

echo -e "${BOLD}${BLUE}🚀 rules_js Development Test Suite${NC}"
echo -e "${BLUE}📊 Config: $MAX_PARALLEL parallel jobs, 10min timeout, fail-fast enabled${NC}"

# Count total tests
total_tests=0
filtered_versions=()

while IFS= read -r version_data; do
    version_json=$(echo "$version_data" | base64 -d)
    version=$(echo "$version_json" | jq -r '.version')
    major=$(echo "$version_json" | jq -r '.major')
    bzlmod_modes_json=$(echo "$version_json" | jq -r '.bzlmod_modes')
    
    # Skip if filtering by version
    if [ -n "$BAZEL_VERSION_FILTER" ] && [ "$version" != "$BAZEL_VERSION_FILTER" ]; then
        continue
    fi
    
    filtered_versions+=("$version_data")
    
    # Count tests for this version
    bzlmod_count=$(echo "$bzlmod_modes_json" | jq 'length')
    e2e_count=${#E2E_TESTS[@]}
    
    # Check if root/docs tests are skipped for this version
    skip_root=$(echo "$version_json" | jq -r '.skip_root_tests // false')
    skip_docs=$(echo "$version_json" | jq -r '.skip_docs_tests // false')
    
    version_tests=$((bzlmod_count * e2e_count))
    if [ "$skip_root" != "true" ]; then
        version_tests=$((version_tests + 1))
    fi
    if [ "$skip_docs" != "true" ]; then
        version_tests=$((version_tests + 1))
    fi
    
    total_tests=$((total_tests + version_tests))
done <<< "$BAZEL_VERSIONS"

if [ ${#filtered_versions[@]} -eq 0 ]; then
    echo -e "${RED}❌ No matching Bazel versions found${NC}"
    if [ -n "$BAZEL_VERSION_FILTER" ]; then
        echo -e "${RED}   Version filter: $BAZEL_VERSION_FILTER${NC}"
    fi
    exit 1
fi

echo -e "${BLUE}📊 Testing: $total_tests total tests across ${#filtered_versions[@]} Bazel version(s)${NC}"

if [ -n "$ORIGINAL_BAZEL_VERSION" ]; then
    echo -e "${BLUE}💾 Original Bazel version: $ORIGINAL_BAZEL_VERSION (will be restored)${NC}"
fi

# Function to run root tests
run_root_tests() {
    local version="$1"
    local major="$2"
    local log_file="$3"
    
    
    local bazelrc_flag=""
    if [ -f ".github/workflows/bazel${major}.bazelrc" ]; then
        bazelrc_flag="--bazelrc .github/workflows/bazel${major}.bazelrc"
    fi
    
    local tag_filter="--test_tag_filters=-skip-on-bazel${major}"
    local build_tag_filter="--build_tag_filters=-skip-on-bazel${major}"
    
    {
        echo "=== Root Repository Tests (Bazel $version) ==="
        echo "Started: $(date)"
        echo
        
        echo "⏳ bazel build //..."
        if bazel build //... $bazelrc_flag $build_tag_filter; then
            echo "✅ Root build completed"
        else
            echo "❌ Root build failed"
            return 1
        fi
        
        echo
        echo "⏳ bazel test //..."
        if bazel test //... $bazelrc_flag $tag_filter $build_tag_filter --test_output=errors; then
            echo "✅ Root tests completed"
        else
            echo "❌ Root tests failed"
            return 1
        fi
        
        echo
        echo "Completed: $(date)"
    } > "$log_file" 2>&1
}

# Function to run docs tests  
run_docs_tests() {
    local version="$1"
    local major="$2"
    local log_file="$3"
    
    local bazelrc_flag=""
    if [ -f ".github/workflows/bazel${major}.bazelrc" ]; then
        bazelrc_flag="--bazelrc ../.github/workflows/bazel${major}.bazelrc"
    fi
    
    {
        echo "=== Documentation Tests (Bazel $version) ==="
        echo "Started: $(date)"
        echo
        
        cd docs
        
        echo "⏳ bazel build //..."
        if bazel build //... $bazelrc_flag; then
            echo "✅ Docs build completed"
        else
            echo "❌ Docs build failed"
            return 1
        fi
        
        echo
        echo "⏳ bazel test //..."
        if bazel test //... $bazelrc_flag --test_output=errors; then
            echo "✅ Docs tests completed"
        else
            echo "❌ Docs tests failed"
            return 1
        fi
        
        echo
        echo "Completed: $(date)"
    } > "$log_file" 2>&1
}

# Read the default Bazel version from .bazelversion for root/docs tests
DEFAULT_VERSION=$(cat .bazelversion | tr -d '\n' | tr -d ' ')

# Main test execution
failed_version=""
tests_completed=0

# Phase 1 & 2: Root and Docs tests - Run only on .bazelversion
echo
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│ Root & Docs Tests (Bazel $DEFAULT_VERSION)${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────┘${NC}"

# Get config for default version to check if tests should be skipped
default_major=$(echo "$DEFAULT_VERSION" | cut -d. -f1)
skip_root_default=$(jq -r --arg major "$default_major" '.bazel_versions[] | select(.major == ($major | tonumber)) | .skip_root_tests // false' "$CONFIG_FILE")
skip_docs_default=$(jq -r --arg major "$default_major" '.bazel_versions[] | select(.major == ($major | tonumber)) | .skip_docs_tests // false' "$CONFIG_FILE")

# Switch to default Bazel version
echo -e "${YELLOW}⏳ Switching to Bazel $DEFAULT_VERSION...${NC}"
echo "$DEFAULT_VERSION" > .bazelversion

# Phase 1: Root tests
if [ "$skip_root_default" = "true" ]; then
    echo -e "${YELLOW}⏭️  Skipping root tests for Bazel $DEFAULT_VERSION (not supported)${NC}"
else
    echo -e "${YELLOW}⏳ Phase 1: Root repository tests${NC}"
    root_log_file="$LOG_DIR/root-bazel$DEFAULT_VERSION.log"

    start_time=$(date +%s)
    if run_root_tests "$DEFAULT_VERSION" "$default_major" "$root_log_file"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        echo -e "${GREEN}✅ Root tests completed (${duration}s)${NC}"
        tests_completed=$((tests_completed + 1))
    else
        echo -e "${RED}❌ Root tests failed${NC}"
        failed_version="$DEFAULT_VERSION"
    fi
fi

# Phase 2: Docs tests (only if root tests passed or were skipped)
if [ -z "$failed_version" ]; then
    if [ "$skip_docs_default" = "true" ]; then
        echo -e "${YELLOW}⏭️  Skipping docs tests for Bazel $DEFAULT_VERSION (not supported)${NC}"
    else
        echo -e "${YELLOW}⏳ Phase 2: Documentation tests${NC}" 
        docs_log_file="$LOG_DIR/docs-bazel$DEFAULT_VERSION.log"
        
        start_time=$(date +%s)
        if run_docs_tests "$DEFAULT_VERSION" "$default_major" "$docs_log_file"; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            echo -e "${GREEN}✅ Docs tests completed (${duration}s)${NC}"
            ((tests_completed++))
        else
            echo -e "${RED}❌ Docs tests failed${NC}"
            failed_version="$DEFAULT_VERSION"
        fi
    fi
else
    echo -e "${YELLOW}🔄 Skipping docs tests due to root test failure${NC}"
fi

# Phase 3: E2E tests - Run on all configured versions (only if no failures)
if [ -z "$failed_version" ]; then
    echo
    echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│ E2E Tests (All Bazel Versions)${NC}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
    
    for version_data in "${filtered_versions[@]}"; do
        version_json=$(echo "$version_data" | base64 -d)
        version=$(echo "$version_json" | jq -r '.version')
        major=$(echo "$version_json" | jq -r '.major')
        bzlmod_modes=$(echo "$version_json" | jq -r '.bzlmod_modes[]')
        
        echo
        echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│ E2E Tests - Bazel $version${NC}"
        if [ "$major" = "6" ]; then
            echo -e "${BOLD}${CYAN}│ (WORKSPACE only - bzlmod not supported)${NC}"
        else
            echo -e "${BOLD}${CYAN}│ (WORKSPACE + bzlmod)${NC}"
        fi
        echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
        
        # Switch Bazel version
        echo -e "${YELLOW}⏳ Switching to Bazel $version...${NC}"
        echo "$version" > .bazelversion
        
        # Run E2E tests
        e2e_count=$(echo "$bzlmod_modes" | wc -l)
        e2e_test_count=${#E2E_TESTS[@]}
        total_e2e=$((e2e_count * e2e_test_count))
        
        echo -e "${YELLOW}⏳ E2E tests ($total_e2e tests)${NC}"
        
        start_time=$(date +%s)
        if "$SCRIPT_DIR/parallel-e2e.sh" "$version" "$MAX_PARALLEL" "$LOG_DIR" "${E2E_TESTS[@]}"; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            echo -e "${GREEN}✅ All Bazel $version e2e tests passed (${duration}s)${NC}"
            tests_completed=$((tests_completed + total_e2e))
        else
            echo -e "${RED}❌ E2E tests failed${NC}"
            failed_version="$version"
            break
        fi
    done
else
    echo -e "${YELLOW}🔄 Skipping E2E tests due to root/docs test failure${NC}"
fi

echo
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"

# Final results
if [ -n "$failed_version" ]; then
    echo -e "${RED}❌ Test suite failed at Bazel $failed_version${NC}"
    echo -e "${RED}📊 Results: $tests_completed/$total_tests tests completed before failure${NC}"
    echo -e "${RED}📁 Logs saved to: $LOG_DIR${NC}"
    echo
    echo -e "${YELLOW}🔧 To investigate the failure:${NC}"
    echo -e "${YELLOW}   1. Check logs in: $LOG_DIR${NC}"
    echo -e "${YELLOW}   2. Look for the most recent *.log files${NC}"
    echo -e "${YELLOW}   3. Failed test logs contain reproduction commands${NC}"
    exit 1
else
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    echo -e "${GREEN}📊 Results: $tests_completed/$total_tests tests completed successfully${NC}"
    
    # Calculate rough total time (this is approximate since we ran sequentially by version)
    if [ ${#filtered_versions[@]} -gt 1 ]; then
        echo -e "${BLUE}📅 Tested ${#filtered_versions[@]} Bazel versions${NC}"
    fi
    
    exit 0
fi