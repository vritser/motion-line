#!/bin/sh
# Standalone verification; no dsh-emacs checkout or network is required.
set -eu
cd "$(dirname "$0")/.."
motion_line_emacs=${EMACS:-emacs}
motion_line_tmp=$(mktemp -d "${TMPDIR:-/tmp}/motion-line-verify.XXXXXX")
trap 'rm -rf "$motion_line_tmp"' EXIT

# Compilation reads the entire source and rejects warnings as well as errors.
env MOTION_LINE_BYTE_TMP="$motion_line_tmp" "$motion_line_emacs" -Q --batch -L . \
  --eval "(require 'bytecomp)" \
  --eval '(setq byte-compile-error-on-warn t byte-compile-dest-file-function (lambda (src) (expand-file-name (concat (file-name-nondirectory src) "c") (getenv "MOTION_LINE_BYTE_TMP"))))' \
  -f batch-byte-compile motion-line.el
"$motion_line_emacs" -Q --batch -L . -l motion-line-test.el \
  -f ert-run-tests-batch-and-exit
motion_line_output=$("$motion_line_emacs" -Q --batch -L . -l motion-line.el 2>&1)
if [ -n "$motion_line_output" ]; then
  printf 'FAIL clean load: %s\n' "$motion_line_output" >&2
  exit 1
fi
printf 'Motion Line verification passed.\n'
