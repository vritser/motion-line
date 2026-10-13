;;; motion-line.el --- Composable mode-line animation -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: mode-line, multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Compose frames, tweens, sequences and parallel tracks into clips, then
;; play them in named buffer-local slots.  One shared timer renders cached
;; strings; redisplay only reads them.  Loading this file starts no timers
;; and does not modify any mode line.  See README.md for examples.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup motion-line nil
  "Composable animations for any mode line."
  :group 'mode-line
  :prefix "motion-line-")

(defcustom motion-line-interval 0.05
  "Seconds between animation updates.
Changes take effect on the next tick.  This is a maximum refresh rate;
Emacs may delay timers while busy.  Playback uses elapsed time."
  :type 'number
  :group 'motion-line)

(defvar motion-line--timer nil "Shared one-shot animation timer.")
(defvar motion-line--buffers nil "Buffers owning playback slots.")
(defvar-local motion-line--players nil "Alist of slot names and players.")

(defvar-local motion-line-redisplay-function #'force-mode-line-update
  "Function called without arguments when a timer changes this buffer's text.
Clients batching other display work can defer the mode-line update here.
Explicit playback controls still request an immediate update.")

(defun motion-line--positive-number-p (value)
  "Return non-nil when VALUE is a finite positive number."
  (and (numberp value) (> value 0) (< value 1.0e+INF)))

(defun motion-line-clip (duration renderer)
  "Create a clip of DURATION seconds using RENDERER.
RENDERER receives local elapsed seconds, clamped to [0, DURATION], and
must return a string.  Text properties, including image `display'
properties, are preserved.  The function runs in the owning buffer.
Treat returned clips as immutable; the same clip can serve many players.
Renderers must be fast and must not start or change playback themselves."
  (unless (motion-line--positive-number-p duration)
    (error "Duration must be finite and positive: %S" duration))
  (unless (functionp renderer)
    (error "Renderer must be a function: %S" renderer))
  (list :duration duration :render renderer))

(defun motion-line-sample (clip seconds)
  "Return CLIP's string at SECONDS without starting playback.
Times outside the clip are clamped to its endpoints."
  (let ((text (funcall (plist-get clip :render)
                       (max 0 (min seconds (plist-get clip :duration))))))
    (unless (stringp text)
      (error "Animation renderer returned a non-string: %S" text))
    text))

(defun motion-line-frames (frames &optional duration)
  "Create a clip from a nonempty sequence of FRAMES.
Each frame is a string or (STRING . SECONDS).  Plain strings last
DURATION seconds, default 0.1.  Strings can carry faces or image display
properties.  The last frame remains visible at the clip's endpoint."
  (when (stringp frames)
    (error "Frames must be a sequence of frames, not a string: %S" frames))
  (unless (and (sequencep frames) (> (length frames) 0))
    (error "Frames must be a nonempty sequence"))
  (let ((end 0) timeline)
    (mapc (lambda (frame)
            (let ((text (if (consp frame) (car frame) frame))
                  (hold (if (consp frame) (cdr frame) (or duration 0.1))))
              (unless (and (stringp text)
                           (motion-line--positive-number-p hold))
                (error "Invalid animation frame: %S" frame))
              (setq end (+ end hold))
              (push (cons end (copy-sequence text)) timeline)))
          frames)
    (setq timeline (nreverse timeline))
    (motion-line-clip
     end (lambda (seconds)
           (let ((remaining timeline))
             (while (and (cdr remaining) (>= seconds (caar remaining)))
               (setq remaining (cdr remaining)))
             (cdar remaining))))))

(defun motion-line-tween (duration renderer &optional easing)
  "Create a tween of DURATION seconds calling RENDERER with progress 0 to 1.
EASING is a function mapping progress to progress; nil means linear.
For example, RENDERER can interpolate position, color, or an SVG transform."
  (unless (and (functionp renderer) (or (null easing) (functionp easing)))
    (error "Tween renderer and easing must be functions"))
  (motion-line-clip
   duration (lambda (seconds)
              (let ((progress (/ (float seconds) duration)))
                (funcall renderer (if easing (funcall easing progress)
                                    progress))))))

(defun motion-line-ease-in-out (progress)
  "Return smoothstep easing for PROGRESS in [0, 1]."
  (* progress progress (- 3 (* 2 progress))))

(defun motion-line--check-clips (clips)
  "Signal an error unless every element of CLIPS is an animation clip."
  (dolist (clip clips)
    (unless (and (listp clip)
                 (motion-line--positive-number-p
                  (plist-get clip :duration))
                 (functionp (plist-get clip :render)))
      (error "Not an animation clip: %S" clip))))

(defun motion-line-sequence (&rest clips)
  "Create a clip playing CLIPS consecutively, without gaps.
Use a single-frame clip to introduce a hold or delay."
  (unless clips (error "A sequence requires at least one clip"))
  (motion-line--check-clips clips)
  (let ((duration (apply #'+ (mapcar (lambda (clip)
                                       (plist-get clip :duration)) clips))))
    (motion-line-clip
     duration
     (lambda (seconds)
       (let ((remaining clips))
         (while (and (cdr remaining)
                     (>= seconds (plist-get (car remaining) :duration)))
           (setq seconds (- seconds (plist-get (car remaining) :duration))
                 remaining (cdr remaining)))
         (motion-line-sample (car remaining) seconds))))))

(defun motion-line-parallel (clips &optional separator)
  "Create a clip playing CLIPS together, joined with SEPARATOR.
The longest clip determines the duration; shorter tracks hold their last
frame.  For image overlays, use one custom renderer instead of joining."
  (unless clips (error "Parallel playback requires at least one clip"))
  (motion-line--check-clips clips)
  (motion-line-clip
   (apply #'max (mapcar (lambda (clip) (plist-get clip :duration)) clips))
   (lambda (seconds)
     (mapconcat (lambda (clip) (motion-line-sample clip seconds))
                clips (or separator "")))))

(defun motion-line--elapsed (player now)
  "Return PLAYER's playback seconds at NOW."
  (+ (plist-get player :offset)
     (if (plist-get player :playing)
         (* (plist-get player :speed)
            (max 0 (- now (plist-get player :since))))
       0)))

(defun motion-line--position (player elapsed)
  "Return (LOCAL-TIME . FINISHED) for PLAYER at ELAPSED seconds."
  (let* ((duration (plist-get (plist-get player :clip) :duration))
         (repeat (plist-get player :repeat))
         (finished (and (integerp repeat) (>= elapsed (* repeat duration))))
         (cycle (if finished (1- repeat) (floor elapsed duration)))
         (local (if finished duration (- elapsed (* cycle duration))))
         (direction (plist-get player :direction)))
    (cons (if (or (eq direction 'reverse)
                  (and (eq direction 'alternate) (= 1 (% cycle 2))))
              (- duration local)
            local)
          finished)))

(defun motion-line--update (player now &optional force)
  "Advance PLAYER at NOW, rendering if visible or FORCE is non-nil.
Return non-nil if its cached text changed.  Finite playback renders its
endpoint even in hidden buffers so it can release the shared timer."
  (let* ((elapsed (motion-line--elapsed player now))
         (position (motion-line--position player elapsed)))
    (when (cdr position)
      (setf (plist-get player :offset)
            (* (plist-get player :repeat)
               (plist-get (plist-get player :clip) :duration))
            (plist-get player :playing) nil))
    (when (or force (cdr position) (get-buffer-window (current-buffer) t))
      (let ((text (motion-line-sample (plist-get player :clip)
                                            (car position))))
        (unless (equal-including-properties text (plist-get player :text))
          ;; Own the cached string even if a renderer reuses a mutable string.
          (setf (plist-get player :text) (copy-sequence text))
          t)))))

(defun motion-line--schedule ()
  "Keep the pending tick while any live buffer has a running player."
  (setq motion-line--buffers
        (cl-delete-if-not #'buffer-live-p motion-line--buffers))
  (if (cl-some
       (lambda (buffer)
         (with-current-buffer buffer
           (cl-some (lambda (entry) (plist-get (cdr entry) :playing))
                    motion-line--players)))
       motion-line--buffers)
      ;; Starting or clearing another slot must not postpone this deadline:
      ;; repeated controls could otherwise starve all running animations.
      (unless motion-line--timer
        (setq motion-line--timer
              (run-at-time
               (if (motion-line--positive-number-p motion-line-interval)
                   (max 0.01 motion-line-interval)
                 0.05)
               nil #'motion-line--tick)))
    (when motion-line--timer
      (cancel-timer motion-line--timer)
      (setq motion-line--timer nil))))

(defun motion-line--tick ()
  "Update running players, isolating renderer errors at the timer boundary."
  (setq motion-line--timer nil)
  (let ((now (float-time)))
    (dolist (buffer motion-line--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let (changed)
            (dolist (entry motion-line--players)
              (when (plist-get (cdr entry) :playing)
                (condition-case err
                    (when (motion-line--update (cdr entry) now)
                      (setq changed t))
                  (error
                   (setf (plist-get (cdr entry) :offset)
                         (motion-line--elapsed (cdr entry) now)
                         (plist-get (cdr entry) :playing) nil)
                   (message "motion-line %s/%s: %s"
                            (buffer-name) (car entry)
                            (error-message-string err))))))
            (when changed
              (condition-case err
                  (funcall motion-line-redisplay-function)
                (error
                 (message "motion-line %s redisplay: %s"
                          (buffer-name) (error-message-string err))))))))))
  ;; One-shot timers avoid a burst of catch-up callbacks after Emacs stalls.
  (motion-line--schedule))

(cl-defun motion-line-play (slot clip &key (repeat t) (speed 1)
                                       (direction 'normal))
  "Play CLIP in buffer-local SLOT, replacing any previous player there.
SLOT is a symbol.  REPEAT is t for infinite playback or a positive integer
number of cycles.  SPEED is a finite positive multiplier.  DIRECTION is
`normal', `reverse' or `alternate' (forward, backward, forward, ...).

Install `(:eval (motion-line-string SLOT))' in your mode line once.
This function does not change `mode-line-format'.  Initial renderer errors
propagate without replacing an existing player.  Later errors pause that
slot and report the error in the echo area and *Messages*."
  (unless (symbolp slot)
    (error "Slot name must be a symbol: %S" slot))
  (unless (or (eq repeat t) (and (integerp repeat) (> repeat 0)))
    (error "Repeat must be t or a positive integer: %S" repeat))
  (unless (motion-line--positive-number-p speed)
    (error "Speed must be finite and positive: %S" speed))
  (unless (memq direction '(normal reverse alternate))
    (error "Direction must be normal, reverse or alternate: %S" direction))
  (let* ((now (float-time))
         (player (list :clip clip :repeat repeat :speed speed
                       :direction direction :offset 0 :since now
                       :playing t :text nil)))
    (motion-line--update player now t)
    (setf (alist-get slot motion-line--players) player)
    (cl-pushnew (current-buffer) motion-line--buffers)
    (add-hook 'kill-buffer-hook #'motion-line-stop-all nil t)
    (add-hook 'change-major-mode-hook #'motion-line-stop-all nil t)
    (motion-line--schedule)
    (force-mode-line-update)
    slot))

(defun motion-line-playing-p (slot)
  "Return non-nil if SLOT is currently playing in this buffer."
  (and (plist-get (alist-get slot motion-line--players) :playing) t))

(defun motion-line-string (slot)
  "Return the cached mode-line text for SLOT, or an empty string.
Literal percent signs are escaped for mode-line expansion.  This function
never calls a renderer or changes playback, so it is safe inside `:eval'."
  ;; A function replacement repeats the matched character, so the escape
  ;; keeps its text properties; a literal replacement would drop them.
  (replace-regexp-in-string
   "%" (lambda (match) (concat match match))
   (or (plist-get (alist-get slot motion-line--players) :text)
       "")
   t t))

(defun motion-line-pause (slot)
  "Pause SLOT at its current time, retaining its visible frame."
  (when-let* ((player (copy-sequence (alist-get slot motion-line--players))))
    (when (plist-get player :playing)
      (let ((now (float-time)))
        (motion-line--update player now t)
        (setf (plist-get player :offset) (motion-line--elapsed player now)
              (plist-get player :playing) nil)))
    (setf (alist-get slot motion-line--players) player)
    (motion-line--schedule)
    (force-mode-line-update)))

(defun motion-line-resume (slot)
  "Resume paused SLOT.  A finished finite animation restarts at zero."
  (when-let* ((player (copy-sequence (alist-get slot motion-line--players))))
    (unless (plist-get player :playing)
      (when (cdr (motion-line--position player (plist-get player :offset)))
        (setf (plist-get player :offset) 0))
      (setf (plist-get player :since) (float-time)
            (plist-get player :playing) t)
      (motion-line--update player (plist-get player :since) t)
      (setf (alist-get slot motion-line--players) player)
      (motion-line--schedule)
      (force-mode-line-update))))

(defun motion-line-seek (slot seconds)
  "Seek SLOT to absolute playback SECONDS, including repeated cycles.
Preserve paused/running state, except seeking past a finite end stops it.
Negative positions clamp to zero."
  (unless (and (numberp seconds) (< (abs seconds) 1.0e+INF))
    (error "Seek position must be finite: %S" seconds))
  (when-let* ((player (copy-sequence (alist-get slot motion-line--players))))
    (setf (plist-get player :offset) (max 0 seconds)
          (plist-get player :since) (float-time))
    (motion-line--update player (plist-get player :since) t)
    (setf (alist-get slot motion-line--players) player)
    (motion-line--schedule)
    (force-mode-line-update)))

(defun motion-line-stop (slot)
  "Remove SLOT from this buffer and release unused timer resources."
  (setq motion-line--players (assq-delete-all slot motion-line--players))
  (if motion-line--players
      (motion-line--schedule)
    (motion-line-stop-all))
  (force-mode-line-update))

(defun motion-line-stop-all ()
  "Remove all animation slots in the current buffer."
  (interactive)
  (setq motion-line--players nil
        motion-line--buffers
        (delq (current-buffer) motion-line--buffers))
  (remove-hook 'kill-buffer-hook #'motion-line-stop-all t)
  (remove-hook 'change-major-mode-hook #'motion-line-stop-all t)
  (motion-line--schedule)
  (force-mode-line-update))

;;;###autoload
(defun motion-line-demo ()
  "Show a composed animation in a dedicated demo buffer.
The demo uses text so it works in terminals as well as graphical Emacs."
  (interactive)
  (pop-to-buffer (get-buffer-create "*Motion Line*"))
  (special-mode)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Motion Line\n\n"
            "A spinner, eased scanner and timed captions play together.\n"
            "The complete composition reverses on alternate cycles.\n\n"
            "Evaluate in this buffer:\n"
            "  (motion-line-pause 'demo)\n"
            "  (motion-line-resume 'demo)\n"
            "  (motion-line-seek 'demo 1.5)\n\n"
            "M-x motion-line-stop-all stops playback.\n"
            "Killing this buffer releases its animation resources.\n"))
  (setq-local mode-line-format
              '(" " mode-line-buffer-identification "  "
                (:eval (motion-line-string 'demo))))
  (motion-line-play
   'demo
   (motion-line-parallel
    (list
     (motion-line-clip
      3 (lambda (seconds) (aref ["|" "/" "-" "\\"]
                                (% (floor (* seconds 10)) 4))))
     (motion-line-tween
      3 (lambda (progress)
          (let ((track (make-string 12 ?.)))
            (aset track (min 11 (floor (* progress 12))) ?O)
            (propertize (concat "[" track "]") 'face 'font-lock-keyword-face)))
      #'motion-line-ease-in-out)
     (motion-line-sequence
      (motion-line-frames '(("Preparing" . 1)))
      (motion-line-frames '(("Working  " . 1)))
      (motion-line-frames '(("Done     " . 1)))))
    " ")
   :direction 'alternate))

(provide 'motion-line)
;;; motion-line.el ends here
