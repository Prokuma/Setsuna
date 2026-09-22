#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Revisions are recorded by the parent repository's gitlinks, including nested env.
git submodule update --init --recursive
