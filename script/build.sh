#!/usr/bin/env bash
# Deprecated: the canonical build is script/build-app.sh. This shim forwards.
exec "$(dirname "${BASH_SOURCE[0]}")/build-app.sh" "$@"
