#!/usr/bin/env bash
# tests/test_validate.sh — Tests for lib/validate.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source_gitsetu_libs

# --- Email tests ---

test_email_valid_simple() {
    assert_exit_code 0 validate_email "user@example.com"
}

test_email_valid_plus() {
    assert_exit_code 0 validate_email "user+tag@example.co.uk"
}

test_email_valid_dots() {
    assert_exit_code 0 validate_email "first.last@domain.org"
}

test_email_invalid_empty() {
    assert_exit_code 1 validate_email ""
}

test_email_invalid_no_at() {
    assert_exit_code 1 validate_email "userexample.com"
}

test_email_invalid_no_local() {
    assert_exit_code 1 validate_email "@example.com"
}

test_email_invalid_no_domain_dot() {
    assert_exit_code 1 validate_email "user@example"
}

test_email_invalid_trailing_dot() {
    assert_exit_code 1 validate_email "user@example."
}

# --- GitHub No-Reply Email tests ---

test_github_email_valid_simple() {
    assert_exit_code 0 validate_github_noreply_email "12345+bhaskar@users.noreply.github.com"
}

test_github_email_valid_hyphen() {
    assert_exit_code 0 validate_github_noreply_email "12345+bhaskar-jha@users.noreply.github.com"
}

test_github_email_invalid_no_plus() {
    assert_exit_code 1 validate_github_noreply_email "12345bhaskar@users.noreply.github.com"
}

test_github_email_invalid_no_id() {
    assert_exit_code 1 validate_github_noreply_email "+bhaskar@users.noreply.github.com"
}

test_github_email_invalid_wrong_domain() {
    assert_exit_code 1 validate_github_noreply_email "12345+bhaskar@github.com"
}

# --- Label tests ---

test_label_valid_simple() {
    assert_exit_code 0 validate_label "pro"
}

test_label_valid_hyphen() {
    assert_exit_code 0 validate_label "work-client"
}

test_label_valid_numbers() {
    assert_exit_code 0 validate_label "project2"
}

test_label_invalid_empty() {
    assert_exit_code 1 validate_label ""
}

test_label_invalid_uppercase() {
    assert_exit_code 1 validate_label "Pro"
}

test_label_invalid_spaces() {
    assert_exit_code 1 validate_label "work client"
}

test_label_invalid_special() {
    assert_exit_code 1 validate_label "work@client"
}

test_label_invalid_starts_number() {
    assert_exit_code 1 validate_label "2work"
}

test_label_invalid_starts_hyphen() {
    assert_exit_code 1 validate_label "-work"
}

test_label_invalid_ends_hyphen() {
    assert_exit_code 1 validate_label "work-"
}

test_label_invalid_too_long() {
    assert_exit_code 1 validate_label "abcdefghijklmnopqrstu"
}


# --- Run ---

printf '\n%btest_validate.sh%b\n' "$T_BOLD" "$T_RESET"

run_test "valid email: simple" test_email_valid_simple
run_test "valid email: with plus tag" test_email_valid_plus
run_test "valid email: with dots" test_email_valid_dots
run_test "invalid email: empty" test_email_invalid_empty
run_test "invalid email: no @" test_email_invalid_no_at
run_test "invalid email: no local part" test_email_invalid_no_local
run_test "invalid email: no domain dot" test_email_invalid_no_domain_dot
run_test "invalid email: trailing dot" test_email_invalid_trailing_dot

run_test "valid github email: simple" test_github_email_valid_simple
run_test "valid github email: hyphen" test_github_email_valid_hyphen
run_test "invalid github email: no plus" test_github_email_invalid_no_plus
run_test "invalid github email: no id" test_github_email_invalid_no_id
run_test "invalid github email: wrong domain" test_github_email_invalid_wrong_domain

run_test "valid label: simple" test_label_valid_simple
run_test "valid label: with hyphen" test_label_valid_hyphen
run_test "valid label: with numbers" test_label_valid_numbers
run_test "invalid label: empty" test_label_invalid_empty
run_test "invalid label: uppercase" test_label_invalid_uppercase
run_test "invalid label: spaces" test_label_invalid_spaces
run_test "invalid label: special chars" test_label_invalid_special
run_test "invalid label: starts with number" test_label_invalid_starts_number
run_test "invalid label: starts with hyphen" test_label_invalid_starts_hyphen
run_test "invalid label: ends with hyphen" test_label_invalid_ends_hyphen
run_test "invalid label: too long (21 chars)" test_label_invalid_too_long

print_results "Validation tests"
