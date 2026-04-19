#!/usr/bin/env bash
set -euo pipefail

cd /workspace/moneta || exit 1
if [ -f ./auto-export ]; then
	. ./auto-export
fi

exec ./build.sh
