#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Fixed revisions, no automatic updates or destructive resets of existing clones.
fetch() {
    name=$1 url=$2 revision=$3
    if [ ! -d "third_party/$name" ]; then
        git clone "$url" "third_party/$name"
        git -C "third_party/$name" checkout --detach "$revision"
    fi
    actual=$(git -C "third_party/$name" rev-parse HEAD)
    if [ "$actual" != "$revision" ]; then
        echo "$name: expected $revision, found $actual; reconcile manually" >&2
        exit 1
    fi
}
fetch softfloat https://github.com/ucb-bar/berkeley-softfloat-3.git a0c6494cdc11865811dec815d5c0049fba9d82a8
fetch riscv-tests https://github.com/riscv-software-src/riscv-tests.git d44511022b356a341a2430cfd65f894b77c35f36
git -C third_party/riscv-tests submodule update --init --recursive
