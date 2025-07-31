#!/bin/bash
set -euo pipefail

# Parallel E2E test execution script for rules_js
# Usage: ./parallel-e2e.sh <bazel_version> <max_parallel> <log_dir> [test1 test2 ...]

# Ensure we're in the repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

BAZEL_VERSION="$1"
BAZEL_MAJOR="${BAZEL_VERSION%%.*}"
MAX_PARALLEL="$2" 
LOG_DIR="$3"
shift 3

# Remaining arguments are the test directories to run
E2E_TESTS=("$@")

# Get bzlmod modes for this Bazel version
if [ "$BAZEL_MAJOR" = "6" ]; then
    BZLMOD_MODES=(0)
else
    BZLMOD_MODES=(0 1)
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check if a test should be excluded
should_exclude_test() {
    local test_dir="$1"
    local bzlmod="$2"
    
    # Check exclusions from config file
    local config_file="${SCRIPT_DIR}/test-config.json"
    if [ -f "$config_file" ]; then
        # Check if this test/bzlmod/bazel combination should be excluded
        local excluded=$(jq -r --arg test "$test_dir" --arg bzlmod "$bzlmod" --arg major "$BAZEL_MAJOR" '
            .exclusions[]? | 
            select(
                (.test == $test) and 
                ((.bzlmod == null) or (.bzlmod == ($bzlmod | tonumber))) and
                ((.bazel_major == null) or (.bazel_major == ($major | tonumber)))
            ) | .reason' "$config_file")
        
        if [ -n "$excluded" ]; then
            echo "$excluded"
            return 0
        fi
    fi
    
    return 1
}

# Job management
declare -A running_jobs=()
declare -A job_info=()
failed=false
total_jobs=0
completed_jobs=0

# Calculate total jobs
for test_dir in "${E2E_TESTS[@]}"; do
    for bzlmod in "${BZLMOD_MODES[@]}"; do
        if ! should_exclude_test "$test_dir" "$bzlmod" >/dev/null 2>&1; then
            total_jobs=$((total_jobs + 1))
        fi
    done
done

echo -e "${BLUE}🏃 Starting ${total_jobs} e2e tests (${#BZLMOD_MODES[@]} bzlmod modes × ${#E2E_TESTS[@]} tests)${NC}"
echo -e "${BLUE}📊 Max parallel jobs: ${MAX_PARALLEL}${NC}"

# Function to run a single e2e test
run_single_test() {
    local test_dir="$1"
    local bzlmod="$2"
    local job_id="${test_dir}-bazel${BAZEL_VERSION}-bzlmod${bzlmod}"
    local log_file="${LOG_DIR}/e2e/${job_id}.log"
    
    mkdir -p "$(dirname "$log_file")"
    
    # Build bazel command with version-specific flags
    local bazelrc_flag=""
    if [ -f ".github/workflows/bazel${BAZEL_MAJOR}.bazelrc" ]; then
        bazelrc_flag="--bazelrc ../.github/workflows/bazel${BAZEL_MAJOR}.bazelrc"
    fi
    
    local bzlmod_flag=""
    if [ "$bzlmod" = "1" ]; then
        bzlmod_flag="--enable_bzlmod=1"
    else
        bzlmod_flag="--enable_bzlmod=0"
    fi
    
    local tag_filter="--test_tag_filters=-skip-on-bazel${BAZEL_MAJOR}"
    local build_tag_filter="--build_tag_filters=-skip-on-bazel${BAZEL_MAJOR}"
    
    (
        echo "=== E2E Test: ${test_dir} (Bazel ${BAZEL_VERSION}, bzlmod=${bzlmod}) ==="
        echo "Command: cd e2e/${test_dir} && timeout 10m bazel test //... ${bazelrc_flag} ${bzlmod_flag} ${tag_filter} ${build_tag_filter}"
        echo "Started: $(date)"
        echo "DEBUG: Current directory: $(pwd)"
        echo "DEBUG: bazelrc_flag='${bazelrc_flag}'"
        echo "DEBUG: bzlmod_flag='${bzlmod_flag}'"
        echo "DEBUG: tag_filter='${tag_filter}'"
        echo "DEBUG: build_tag_filter='${build_tag_filter}'"
        echo
        
        cd "e2e/${test_dir}"
        echo "DEBUG: Changed to directory: $(pwd)"
        
        # Run bazel test with timeout
        if timeout 10m bazel test //... \
            $bazelrc_flag \
            $bzlmod_flag \
            $tag_filter \
            $build_tag_filter \
            --test_output=errors 2>&1; then
            echo
            echo "✅ PASSED: ${test_dir} (bzlmod=${bzlmod})"
            echo "Completed: $(date)"
            exit 0
        else
            local exit_code=$?
            echo
            echo "❌ FAILED: ${test_dir} (bzlmod=${bzlmod}) - Exit code: ${exit_code}"
            echo "Completed: $(date)"
            exit $exit_code
        fi
    ) > "$log_file" 2>&1
}

# Function to wait for a job to complete
wait_for_job() {
    local pid="$1"
    local job_info_str="${job_info[$pid]}"
    
    if wait "$pid"; then
        echo -e "${GREEN}✅ ${job_info_str}${NC}"
        completed_jobs=$((completed_jobs + 1))
        echo -e "${BLUE}📊 Progress: ${completed_jobs}/${total_jobs}${NC}"
    else
        local exit_code=$?
        echo -e "${RED}❌ ${job_info_str} - FAILED${NC}"
        echo -e "${RED}🛑 First failure detected, stopping all tests${NC}"
        failed=true
        
        # Kill all running jobs
        for running_pid in "${!running_jobs[@]}"; do
            if [ "$running_pid" != "$pid" ]; then
                kill "$running_pid" 2>/dev/null || true
                wait "$running_pid" 2>/dev/null || true
            fi
        done
        
        return $exit_code
    fi
}

# Function to start a job
start_job() {
    local test_dir="$1"
    local bzlmod="$2"
    local job_info_str="${test_dir} (bzlmod=${bzlmod})"
    
    # Check if this test should be excluded
    local exclusion_reason
    if exclusion_reason=$(should_exclude_test "$test_dir" "$bzlmod"); then
        echo -e "${YELLOW}⏭️  Skipping ${job_info_str} - ${exclusion_reason}${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}⏳ ${job_info_str}${NC}"
    
    # Start the job in background
    run_single_test "$test_dir" "$bzlmod" &
    local pid=$!
    
    running_jobs[$pid]=1
    job_info[$pid]="$job_info_str"
    return 0
}

# Main execution loop
job_queue=()

# Build job queue
for test_dir in "${E2E_TESTS[@]}"; do
    for bzlmod in "${BZLMOD_MODES[@]}"; do
        if ! should_exclude_test "$test_dir" "$bzlmod" >/dev/null 2>&1; then
            job_queue+=("$test_dir:$bzlmod")
        fi
    done
done

# Process job queue
job_index=0
while [ $job_index -lt ${#job_queue[@]} ] || [ ${#running_jobs[@]} -gt 0 ]; do
    # Start new jobs up to the parallel limit
    while [ ${#running_jobs[@]} -lt $MAX_PARALLEL ] && [ $job_index -lt ${#job_queue[@]} ]; do
        job="${job_queue[$job_index]}"
        test_dir="${job%:*}"
        bzlmod="${job#*:}"
        
        start_job "$test_dir" "$bzlmod"
        job_index=$((job_index + 1))
        
        if [ "$failed" = true ]; then
            break
        fi
    done
    
    if [ "$failed" = true ]; then
        break
    fi
    
    # Wait for at least one job to complete
    if [ ${#running_jobs[@]} -gt 0 ]; then
        # Get the first running job
        for pid in "${!running_jobs[@]}"; do
            wait_for_job "$pid"
            unset running_jobs[$pid]
            unset job_info[$pid]
            break
        done
    fi
    
    if [ "$failed" = true ]; then
        break
    fi
done

# Final status
if [ "$failed" = true ]; then
    echo -e "${RED}❌ E2E tests failed${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All ${total_jobs} e2e tests passed${NC}"
    exit 0
fi