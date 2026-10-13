# Changelog

User-visible changes to Motion Line are recorded here. The initial version
is under development; a release date will be added when it is published.

## 0.1.0 - Unreleased

### Added

- **Composable animation clips**: build timelines from text or image frames,
  custom renderers and eased tweens. Nest sequences and parallel tracks to
  combine animations; give individual frames different hold times.
- **Independent playback controls**: play clips in named, buffer-local slots
  with finite or infinite repeats, speed control, reverse or alternating
  playback, pause, resume and seek.
- **Deterministic timing seams**: `motion-line-current-time-function` and
  `motion-line-visible-p-function` expose the playback clock and the
  render-visibility decision. Rebinding them drives playback from a
  deterministic or virtual clock, and renders into an undisplayed buffer,
  without stubbing built-in functions that compiled code calls directly.
- **Shared scheduling**: one timer advances running slots using elapsed time.
  Hidden buffers skip intermediate rendering, and buffer death or major-mode
  changes clean up their slots. Paused and completed slots retain their output
  without keeping a timer alive on their own.
- **Mode-line integration**: read cached output with `motion-line-string`,
  preserving text properties and escaping literal percent signs. Use the
  optional redisplay callback to coordinate updates with a custom mode line.
- **Interactive demo**: `M-x motion-line-demo` combines a spinner, eased
  scanner and timed captions in a dedicated buffer.

Requires Emacs 27.1 or later and no third-party packages. See the
[playback design record](postmortem/001-composable-playback.md) for the
reasoning behind the composition and scheduling model.
