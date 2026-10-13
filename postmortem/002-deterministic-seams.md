# 002 — Deterministic seams instead of stubbed built-in functions

## Background

Tests pinned playback time and visibility by `cl-letf` on the built-in
functions `float-time` and `get-buffer-window`. That stub only works while
those subrs stay reachable through the function cell. Emacs compiles packages
natively, and a host that disables subr trampolines
(`comp-enable-subr-trampolines` nil, which dsh-emacs sets to avoid a gcc
trampoline during its batch run) makes compiled code call the built-in
directly, so the stub is silently ignored.

A client integration test hit exactly that: `motion-line-play` recorded the
real clock while `motion-line--tick` read the stubbed one, elapsed time
clamped to zero, the cached frame never changed, and the redisplay callback
never ran. The failure looked like a mode-line bug and only appeared against a
natively compiled install.

## Decision

Read the clock through the public variable `motion-line-current-time-function`
(default `#'float-time`) and the render-visibility decision through
`motion-line-visible-p-function` (default: displayed in any window), at every
playback control, tick and render decision. Tests rebind those variables
instead of stubbing built-in functions.

## Why

A variable read cannot be direct-linked or optimized away, so the seam works
in interpreted, byte-compiled and natively compiled builds, whatever the host
does with subr trampolines. Expressing the seam as a supported variable also
gives clients a way to drive playback from a virtual clock or to render into
an undisplayed buffer without reaching into the scheduler, and it keeps the
default behavior identical for callers that never rebind them.

Rejected alternatives: **stubbing the subrs** (fails for compiled code, as
above); **declaring the built-ins `defvar`-style no-op aliases** (they are
subrs, and the host controls trampolines, not the library); **making
`motion-line--tick` force-render always** (loses the hidden-buffer rendering
saving that `postmortem/001` relies on).

## Consequence

The suite binds the two variables, so timing assertions are exact and
independent of compilation. dsh-emacs' running-status tests bind them too and
no longer touch built-in subrs. Playback behavior is unchanged for anyone who
never rebinds the seams.

## Known limitations

The seams are process-global rather than buffer-local: one binding affects
every buffer in the process, which suits a clock but means two buffers cannot
have different virtual times. Scheduling still uses real `run-at-time`, so the
suite cancels the pending timer and calls `motion-line--tick` directly. Two
remaining tests in `motion-line-test.el` stub `message` and `run-at-time` by
function cell; they are safe under this repository's own `scripts/verify.sh`,
which leaves subr trampolines enabled, and would need their own seams before
that suite could run against a host that disables them.
