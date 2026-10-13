# Motion Line

Composable motion for your Emacs mode line.

The name pairs motion with Emacs mode lines.

A standalone Emacs 27.1+ package for composing mode-line animations.
No third-party packages or external processes are required.

- Text, faces, and image frames with individual hold times.
- Custom renderers and eased tweens for position, color, or SVG transforms.
- Nested sequences and parallel tracks.
- Infinite or finite repeats, reverse and alternating playback, and speed.
- Independent buffer-local slots with pause, resume, seek, and stop.
- One shared timer; redisplay reads cached strings. Controlling another slot
  preserves the pending tick so running animations keep advancing.

## Try it

Add this directory to `load-path`, then run `M-x motion-line-demo`:

```elisp
(add-to-list 'load-path "/path/to/motion-line")
(require 'motion-line)
(motion-line-demo)
```

You can also install `motion-line.el` with `M-x package-install-file`.
Loading the package does not start playback or change your mode line.

## Put an animation in your mode line

Evaluate this in the buffer where you want playback:

```elisp
(setq-local mode-line-format
            (append mode-line-format
                    '((:eval (motion-line-string 'activity)))))

(motion-line-play
 'activity
 (motion-line-frames [" | " " / " " - " " \\ "] 0.1))
```

Install the `:eval` element once. Start and stop the slot as work begins and
ends. Slots disappear on buffer death or major-mode changes. To install the
element for all buffers, use `setq-default` instead of `setq-local`; playback
is still buffer-local. In a custom mode-line package, use
`(motion-line-string 'activity)` in its segment definition.

`motion-line-string` returns mode-line-ready text with literal `%`
escaped. `motion-line-sample` returns raw text for other display uses.
Both preserve text properties, including faces, help text, and images.

## Compose a timeline

Clips are reusable values. Sequences play clips consecutively; parallel clips
concatenate their tracks and hold shorter tracks at their final frame.
These operations can nest arbitrarily.

```elisp
(setq my-animation
      (motion-line-parallel
       (list
        (motion-line-tween
         3.0
         (lambda (progress)
           (let* ((size 12)
                  (filled (round (* size progress))))
             (propertize
              (concat "[" (make-string filled ?=)
                      (make-string (- size filled) ?.) "]")
              'face 'success)))
         #'motion-line-ease-in-out)
        (motion-line-sequence
         (motion-line-frames '(("Prepare" . 0.5)))
         (motion-line-frames '(("Process" . 2.0)))
         (motion-line-frames '(("Ready  " . 0.5)))))
       " "))

(motion-line-play 'activity my-animation
                        :repeat 4 :speed 1.5 :direction 'alternate)
```

Every repeat is one traversal. With `:repeat 4 :direction 'alternate`, this
plays forward, backward, forward, backward. A finite clip holds its final
frame and releases its timer when finished. To add a delay, insert a
single-frame clip containing a blank string of the desired display width.

## SVG and other images

Frames are propertized strings, so ordinary Emacs image descriptors work.
Precompute a bounded frame set to avoid parsing SVG during playback. This
example animates two orbiting dots with a changing center radius; it falls
back to text when SVG display is unavailable:

```elisp
(setq my-orbit
      (if (and (display-graphic-p) (image-type-available-p 'svg))
          (motion-line-frames
           (cl-loop
            for i below 48
            for angle = (* 2 float-pi (/ i 48.0))
            for x = (+ 18 (* 13 (cos angle)))
            for y = (+ 10 (* 6 (sin angle)))
            collect
            (propertize
             "orbit" 'display
             (create-image
              (format
               (concat
                "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='20'>"
                "<ellipse cx='18' cy='10' rx='13' ry='6' fill='none' "
                "stroke='#65758b' stroke-width='1'/>"
                "<circle cx='18' cy='10' r='%.2f' fill='#8b9dff'/>"
                "<circle cx='%.2f' cy='%.2f' r='2.5' fill='#57d3cc'/>"
                "<circle cx='%.2f' cy='%.2f' r='1.8' fill='#ffbb70'/>"
                "</svg>")
               (+ 2.5 (* 0.8 (sin (* 2 angle)))) x y (- 36 x) (- 20 y))
              'svg t :ascent 'center)))
           0.05)
        (motion-line-frames ["|" "/" "-" "\\"] 0.1)))

(motion-line-play 'activity my-orbit)
```

The same approach works with PNG frames: put each `create-image` result on
a string's `display` property. Image decoding, availability, and dimensions
are owned by Emacs. This package does not decode GIF/video or generate assets.
Use a single SVG renderer for overlapping layers; parallel tracks lay out
strings side by side.

## Playback API

All operations act on the current buffer.

| Function | Effect |
| --- | --- |
| `(motion-line-play SLOT CLIP &key repeat speed direction)` | Start or replace a slot |
| `(motion-line-pause SLOT)` | Freeze at the current playback time |
| `(motion-line-resume SLOT)` | Resume; restart from zero if finished |
| `(motion-line-seek SLOT SECONDS)` | Seek across the entire repeated timeline |
| `(motion-line-stop SLOT)` | Remove one slot |
| `(motion-line-stop-all)` | Remove all slots; also an interactive command |
| `(motion-line-playing-p SLOT)` | Test whether a slot is running |
| `(motion-line-string SLOT)` | Read cached text; missing slots return `""` |
| `(motion-line-sample CLIP SECONDS)` | Render a raw clip sample without playback |

`repeat` defaults to `t` (forever), or accepts a positive integer. `speed`
defaults to 1 and must be positive. `direction` accepts `normal`, `reverse`,
or `alternate`. Seeking preserves pause state; seeking to or past a finite
end finishes the animation. Pausing/resuming an absent slot does nothing.

Construct a custom clip with `(motion-line-clip DURATION RENDERER)`.
Its renderer receives local seconds in `[0, DURATION]`. A tween's renderer
receives eased progress instead. Renderers must return strings, run quickly,
and avoid changing playback themselves. They run in the owning buffer,
not once per displaying window. Initial render errors propagate before slot
replacement; timer errors pause the failing slot, retain its last good frame,
and report the error in `*Messages*`. Other slots continue.
Errors during pause, resume or seek propagate and preserve the prior state.

## Timing and cost

`motion-line-interval` defaults to 0.05 seconds (at most 20 updates per
second). The scheduler clamps positive intervals below 0.01 to 0.01; invalid
values use 0.05. Changes apply on the next tick.

Playback derives from wall-clock elapsed time, so delayed timers skip ahead
instead of slowing the animation or replaying missed frames. Emacs timers
are cooperative, so this does not promise a fixed frame rate. See the
[Emacs timer documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html).
System-clock adjustments can shift playback; backward adjustments clamp
elapsed time to zero until the clock catches up with the player's start.

Hidden buffers skip intermediate rendering and catch up on the next visible
tick. A finite animation renders its final frame even when hidden. Running
hidden animations still share the scheduling timer. Paused/completed players
use no timer unless another slot is running. Redraw requests occur only when
text or its properties change, following Emacs's
[mode-line update contract](https://www.gnu.org/software/emacs/manual/html_node/elisp/Mode-Line-Basics.html).

Clients batching other display updates can set the buffer-local
`motion-line-redisplay-function` to a no-argument function. It runs in
that buffer after timer-driven text changes and can defer a redraw until the
client's pending paint. Its default is `force-mode-line-update`; explicit
playback controls still request updates immediately. Callback errors are
reported at the timer boundary, and scheduling continues.

Playback reads its clock and its visibility decision through
`motion-line-current-time-function` (default `float-time`) and
`motion-line-visible-p-function` (default: displayed in any window). Rebinding
them drives playback from a deterministic or virtual clock, or renders into an
undisplayed buffer. The test suite uses both instead of stubbing built-in
functions, which compiled code may call without consulting the function cell.

Keep frame widths consistent to avoid mode-line movement. This package does
not reserve columns or resize images automatically. SVG support is optional;
choose your own text fallback for image clips. A clip created from cached
images should be rebuilt if its colors or target display capabilities change.

## Tests

From this directory:

```sh
emacs -Q --batch -L . -l motion-line-test.el \
  -f ert-run-tests-batch-and-exit
```

Run `scripts/verify.sh` for byte compilation, the ERT
suite and a silent clean load. Set `EMACS=/path/to/emacs` to test another
Emacs version. The script leaves no compiled files in the checkout.
Tests cover timing, composition, repeats, playback controls, error isolation,
display properties, hidden buffers, and resource cleanup. Timing and
visibility come from the seams above, so timing assertions stay deterministic
in interpreted, byte-compiled and natively compiled builds.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
