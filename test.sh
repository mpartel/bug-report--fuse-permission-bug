#!/bin/bash
# Based on repro script of https://github.com/mpartel/bindfs/issues/120 by wentam@

if [ $# -lt 1 ]; then
  echo "Usage: [mirror user]";
  exit 1;
fi

export program_dir="$(realpath $(dirname "${0}"))"
export test_dir=/testing
export mirror_user="${1}"

# Make sure everything goes away when done
trap "umount -l ${test_dir}/b; trap - SIGTERM; kill -- -$$" SIGINT SIGTERM EXIT

check_cmd() {
  cmd="$1"
  command -v $cmd > /dev/null;
  if [ $? -eq 1 ]; then echo "==> You don't have $cmd, exiting."; exit 1; fi
}

validate_env() {
  set +e
  check_cmd sudo
  check_cmd cc
  check_cmd strace
  check_cmd find
  check_cmd xargs
  check_cmd umount
  check_cmd bash

  echo "Creating directory $test_dir via sudo"
  sudo mkdir -p $test_dir
  sudo chown $(id -u):$(id -g) $test_dir
  sudo chmod a+rX $test_dir

  ls "$test_dir" > /dev/null
  if [ $? -ne 0 ]; then
    echo "==> Unable to access test dir as script user ($(whoami)), exiting";
    exit 1;
  fi

  if [ "$(id -u)" -eq "$(id -u ${mirror_user})" ]; then
    echo "==> Mirror user must be different than the user running this script, exiting";
    exit 1;
  fi

  echo "==> Changing to user '$mirror_user' via sudo, may prompt sudo password:"
  sudo -u "$mirror_user" echo > /dev/null
  if [ $? -ne 0 ]; then echo "==> Unable to switch to mirror user with sudo, exiting"; exit 1; fi

  sudo -u "$mirror_user" ls "$test_dir" > /dev/null
  if [ $? -ne 0 ]; then
    echo "==> Unable to access test dir as mirror user (${mirror_user}), exiting";
    exit 1;
  fi
}

build_program() {
  echo "Building modified 'passthrough' program..."
  cc -Wall -DHAVE_UTIMENSAT=1 -DHAVE_SETXATTR=1 passthrough.c $(pkg-config fuse3 --cflags --libs) -o passthrough
  if [ $? -ne 0 ]; then
    echo "Failed to build modified 'passthrough' filesystem."
    exit 1
  fi
}

setup() {
  set -e
  mkdir -p "$test_dir"
  cd "$test_dir"
  echo -n "Setting up..."
  mkdir -p a b
  $program_dir/passthrough --plus -f -oallow_other -odefault_permissions $test_dir/b/ > /tmp/passthrough.log 2>&1 &
  subpath=$test_dir/a
  while ! grep -q $test_dir /etc/mtab ; do
    echo -n .
    sleep 1
  done
  sleep 1 # Wait for filesystem to start
  mkdir -p b/$subpath/sub/
  chmod 777 "$test_dir"

  filecount="$(find b/$subpath/sub/ -type f | wc -l)"

  if [ $filecount -lt 20000 ]; then
    for f in {1..20000}; do touch b/$subpath/sub/$f; done
  fi

  echo "done"
}

statter() {
  set -e
  while true; do
    find "${1}" -print0 | xargs -0 -n 100 -P 100 stat 2>/dev/null >/dev/null;
    # Either of the following also trigger the issue on my machine, but more slowly
    #find "${1}" >/dev/null
    #stat "${1}"
  done > /dev/null
}

try_for_error() {
  echo "Trying to produce error"

  set +e
  while true; do
    strace -o /tmp/passthrough-repro-strace1 rm -f "${test_dir}/b/${subpath}/foo";
    if [ $? -ne 0 ]; then
      echo -e "\n==> Successfully reproduced: Error occured in rm, see /tmp/passthrough-repro-strace1";
      break;
    fi

    strace -o /tmp/passthrough-repro-strace2 touch "${test_dir}/b/${subpath}/foo";
    if [ $? -ne 0 ]; then
      echo -e "\n==> Successfully reproduced: Error occured in touch, see /tmp/passthrough-repro-strace2";
      break;
    fi
  done
}

validate_env
build_program
setup
cd "$test_dir"
sudo -u "$mirror_user" bash -c "$(declare -f statter); statter ${test_dir}/b/${subpath} &"
echo "C-c to stop, will automatically stop on error"
try_for_error
