#!/usr/bin/env bash
# tests/run_all.sh — Runs all GitSetu regression test suites
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

failed=0
total=0
failed_files=()

for f in tests/test_*.sh; do
    total=$((total + 1))
    echo "=== Running $f ==="
    if bash "$f"; then
        echo ""
    else
        failed=$((failed + 1))
        failed_files+=("$f")
        echo "FAIL in $f"
    fi
done

echo "=========================================="
echo "TEST SUITE SUMMARY"
echo "=========================================="
echo "Total suites run: $total"
echo "Passed:           $((total - failed))"
echo "Failed:           $failed"

if [ "$failed" -gt 0 ]; then
    echo ""
    echo "Failed test files:"
    for ff in "${failed_files[@]}"; do
        echo "  - $ff"
    done
    exit 1
else
    echo ""
    echo "ALL TESTS PASSED SUCCESSFULLY"
fi
