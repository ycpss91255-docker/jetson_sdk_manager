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

@test "lbzip2 is installed" {
  assert_cmd_installed lbzip2
}

@test "root can use sudo" {
  run sudo -n su -c "sudo -n true" root
  assert_success
}

@test "usbutils is installed" {
  assert_cmd_installed lsusb
}

@test "udevadm is installed" {
  assert_cmd_installed udevadm
}

@test "file command is installed" {
  assert_cmd_installed file
}

@test "ssh-keygen is installed" {
  assert_cmd_installed ssh-keygen
}
