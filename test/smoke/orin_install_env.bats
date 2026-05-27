#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}

@test "sdkmanager is installed" {
  assert_cmd_installed sdkmanager
}

@test "sdkmanager is runnable" {
  run sdkmanager --ver
  assert_success
}
