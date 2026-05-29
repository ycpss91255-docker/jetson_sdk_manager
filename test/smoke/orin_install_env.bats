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

@test "sdkmanager is installed (inspector stage only)" {
  command -v sdkmanager >/dev/null 2>&1 \
    || skip "sdkmanager only ships in the inspector stage"
  assert_cmd_installed sdkmanager
}

@test "sdkmanager is runnable (inspector stage only)" {
  command -v sdkmanager >/dev/null 2>&1 \
    || skip "sdkmanager only ships in the inspector stage"
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

@test "simg2img is installed (NVMe/USB flash)" {
  assert_cmd_installed simg2img
}

@test "pv is installed (flash progress)" {
  assert_cmd_installed pv
}

@test "kpartx is installed (partition mapping)" {
  assert_cmd_installed kpartx
}

@test "wget is installed (BSP/rootfs tarball download)" {
  assert_cmd_installed wget
}
