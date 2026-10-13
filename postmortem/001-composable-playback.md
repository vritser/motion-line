# 001 — Separate animation clips from playback

## Background

A mode line can display several animations at once: a spinner, changing
text, a color transition or a sequence of images. These need independent
controls, but rendering from mode-line evaluation repeats work whenever
Emacs redisplays. Per-animation timers also multiply scheduling and cleanup
across buffers.

Motion Line needs a way to compose this content while keeping redisplay
cheap and playback ownership explicit. This record describes the design in
this project's initial implementation in [motion-line.el](../motion-line.el).

## Decision

Represent a clip as a duration and a function from local elapsed time to a
string. Frames, tweens, sequences and parallel tracks all produce this same
shape, so their output can be composed recursively.

Keep mutable playback state in named, buffer-local slots. A slot owns its
position, repeat count, speed, direction and cached output; multiple slots
can reuse one clip without sharing their controls.

Use one shared, one-shot timer to advance running slots. Mode-line evaluation
reads cached output through `motion-line-string`. Callers own placement in
`mode-line-format` and can supply a redisplay callback to coordinate updates.

## Why

Separating content from playback makes composition independent of scheduling.
A renderer only needs to describe a sample at a given time. Reusing Emacs
strings and text properties also lets text, faces and images pass through
the same API without a second image or scene abstraction.

Elapsed-time sampling skips missed frames when Emacs is busy. A one-shot
timer avoids bursts of overdue callbacks, and keeping an existing scheduled
tick prevents controls in one buffer from postponing another buffer's work.
Rendering outside redisplay bounds how often renderers run and lets the
timer boundary pause a failing slot while other slots continue.

Buffer ownership gives cleanup a natural home: killing a buffer or changing
its major mode removes its slots. Keeping mode-line placement with callers
allows native and third-party layouts to use the same engine.

## Consequence

The runtime is a single file with no third-party dependencies. Loading it
starts no playback and changes no mode line. Applications supply their own
content and start and stop slots as needed. Paused and completed slots retain
their output; when no slot is running, the shared timer is released.

The [ERT suite](../motion-line-test.el) exercises composition, controls,
resource cleanup, cached text properties, hidden buffers and error isolation.

## Known limitations

Emacs timers are cooperative, and wall-clock adjustments can shift playback;
the engine does not guarantee a fixed frame rate. Hidden running slots still
keep the shared timer active even though they skip intermediate rendering.

Renderers are synchronous and buffer-scoped, so slow renderers can delay
other work. Parallel tracks concatenate strings rather than overlay images.
Callers own image decoding, theme adaptation and display dimensions, and
should precompute bounded image frame sets when rendering is expensive.
