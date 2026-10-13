;;; motion-line-test.el --- Animation tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with emacs -Q --batch -L . -l motion-line-test.el
;;          -f ert-run-tests-batch-and-exit.

;;; Code:

(require 'ert)
(require 'motion-line)

(defvar motion-line-test--now 100)
(defvar motion-line-test--visible t)

(defun motion-line-test--run (body)
  "Run BODY in an isolated buffer with deterministic time and visibility."
  (let ((motion-line--buffers nil)
        (motion-line--timer nil)
        (motion-line-test--now 100)
        (motion-line-test--visible t)
        (motion-line-current-time-function
         (lambda () motion-line-test--now))
        (motion-line-visible-p-function
         (lambda () motion-line-test--visible)))
    (unwind-protect
        (with-temp-buffer (funcall body))
      (when motion-line--timer
        (cancel-timer motion-line--timer)))))

(defun motion-line-test--tick (seconds)
  "Advance to SECONDS and run one scheduler callback."
  (setq motion-line-test--now seconds)
  (when motion-line--timer
    (cancel-timer motion-line--timer))
  (motion-line--tick))

(ert-deftest motion-line-test-frames ()
  (let* ((label (propertize "B" 'face 'bold))
         (clip (motion-line-frames (list '("A" . 1) (cons label 2)))))
    (should (= (plist-get clip :duration) 3))
    (should (equal (motion-line-sample clip -1) "A"))
    (should (equal (motion-line-sample clip 0.99) "A"))
    (should (equal (motion-line-sample clip 1) "B"))
    (should (eq (get-text-property 0 'face (motion-line-sample clip 8))
                'bold))))

(ert-deftest motion-line-test-compose ()
  (let* ((a (motion-line-frames '("a" "b") 1))
         (b (motion-line-frames '("X") 1))
         (sequence (motion-line-sequence a b))
         (parallel (motion-line-parallel (list a b) ":")))
    (should (equal (motion-line-sample sequence 1) "b"))
    (should (equal (motion-line-sample sequence 2) "X"))
    (should (equal (motion-line-sample sequence 3) "X"))
    (should (= (plist-get parallel :duration) 2))
    (should (equal (motion-line-sample parallel 2) "b:X"))))

(ert-deftest motion-line-test-tween ()
  (let ((clip (motion-line-tween
               4 (lambda (p) (format "%.5f" p))
               #'motion-line-ease-in-out)))
    (should (equal (motion-line-sample clip 0) "0.00000"))
    (should (equal (motion-line-sample clip 1) "0.15625"))
    (should (equal (motion-line-sample clip 2) "0.50000"))
    (should (equal (motion-line-sample clip 9) "1.00000"))))

(ert-deftest motion-line-test-validation ()
  (dolist (duration '(0 -1 nil "fast" 1.0e+INF 0.0e+NaN))
    (should-error (motion-line-clip duration #'identity)))
  (should-error (motion-line-frames []))
  (should-error (motion-line-frames "abc"))
  (should-error (motion-line-frames '(1)))
  (should-error (motion-line-frames '(("a" . 0))))
  (should-error (motion-line-sequence))
  (should-error (motion-line-sequence "not-a-clip"))
  (should-error (motion-line-parallel nil))
  (should-error (motion-line-parallel (list 42)))
  (should-error (motion-line-sample
                 (motion-line-clip 1 (lambda (_) nil)) 0)))

(ert-deftest motion-line-test-play-option-validation ()
  (motion-line-test--run
   (lambda ()
     (let ((clip (motion-line-frames '("A"))))
       (should-error (motion-line-play "x" clip))
       (should-error (motion-line-play 'x clip :repeat 0))
       (should-error (motion-line-play 'x clip :speed 0))
       (should-error (motion-line-play 'x clip :direction 'sideways))
       (should (string-match-p
                "Repeat must be"
                (condition-case err
                    (motion-line-play 'x clip :repeat 0)
                  (error (error-message-string err)))))
       (should (string-match-p
                "Direction must be"
                (condition-case err
                    (motion-line-play 'x clip :direction 'sideways)
                  (error (error-message-string err)))))
       (should-not motion-line--players)))))

(ert-deftest motion-line-test-elapsed-speed-and-finish ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "B" "C") 1)
                             :speed 2 :repeat 1)
     (should (timerp motion-line--timer))
     (motion-line-test--tick 100.6)
     (should (equal (motion-line-string 'x) "B"))
     ;; A delayed callback jumps straight to the endpoint.
     (motion-line-test--tick 120)
     (should (equal (motion-line-string 'x) "C"))
     (should-not motion-line--timer)
     (motion-line-resume 'x)
     (should (equal (motion-line-string 'x) "A"))
     (should (timerp motion-line--timer)))))

(ert-deftest motion-line-test-direction-and-repeat ()
  (motion-line-test--run
   (lambda ()
     (let ((clip (motion-line-tween 2 (lambda (p) (format "%.2f" p)))))
       (motion-line-play 'x clip :direction 'alternate :repeat 2)
       (motion-line-test--tick 101)
       (should (equal (motion-line-string 'x) "0.50"))
       (motion-line-test--tick 102)
       (should (equal (motion-line-string 'x) "1.00"))
       (motion-line-test--tick 102.5)
       (should (equal (motion-line-string 'x) "0.75"))
       (motion-line-test--tick 104)
       (should (equal (motion-line-string 'x) "0.00"))
       (should-not motion-line--timer)
       (motion-line-play 'x clip :direction 'reverse :repeat 1)
       (should (equal (motion-line-string 'x) "1.00"))
       (motion-line-test--tick 106)
       (should (equal (motion-line-string 'x) "0.00"))))))

(ert-deftest motion-line-test-pause-resume-seek ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "B" "C") 1))
     (setq motion-line-test--now 101.25)
     (motion-line-pause 'x)
     (should (equal (motion-line-string 'x) "B"))
     (should-not motion-line--timer)
     (setq motion-line-test--now 200)
     (motion-line-resume 'x)
     (motion-line-test--tick 200.8)
     (should (equal (motion-line-string 'x) "C"))
     (motion-line-pause 'x)
     (motion-line-seek 'x 0.25)
     (should (equal (motion-line-string 'x) "A"))
     (should-not motion-line--timer)
     (should-error (motion-line-seek 'x 1.0e+INF)))))

(ert-deftest motion-line-test-hidden-buffers ()
  (motion-line-test--run
   (lambda ()
     (let ((calls 0))
       (motion-line-play
        'x (motion-line-clip 4 (lambda (seconds)
                                       (cl-incf calls) (format "%.0f" seconds))))
       (setq motion-line-test--visible nil)
       (motion-line-test--tick 102)
       (should (= calls 1))
       (setq motion-line-test--visible t)
       (motion-line-test--tick 103)
       (should (equal (motion-line-string 'x) "3"))
       (should (= calls 2))))))

(ert-deftest motion-line-test-hidden-finite-endpoint ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "Z") 1) :repeat 1)
     (setq motion-line-test--visible nil)
     (motion-line-test--tick 110)
     (should (equal (motion-line-string 'x) "Z"))
     (should-not motion-line--timer))))

(ert-deftest motion-line-test-render-cache-and-properties ()
  (motion-line-test--run
   (lambda ()
     (let ((calls 0) (image '(image :type svg :data "placeholder")))
       (motion-line-play
        'x (motion-line-clip
            2 (lambda (seconds)
                (cl-incf calls)
                (propertize "50%" 'display image
                            'face (if (< seconds 1) 'bold 'italic)))))
       (dotimes (_ 10) (motion-line-string 'x))
       (should (= calls 1))
       (should (equal (motion-line-string 'x) "50%%"))
       (should (equal (get-text-property 0 'display (motion-line-string 'x))
                      image))
       (motion-line-test--tick 101)
       (should (eq (get-text-property 0 'face (motion-line-string 'x))
                   'italic))))))

(ert-deftest motion-line-test-percent-escaping-keeps-properties ()
  (motion-line-test--run
   (lambda ()
     (let ((image '(image :type svg :data "placeholder")))
       (motion-line-play
        'x (motion-line-clip
            2 (lambda (_) (propertize "50%" 'face 'bold 'display image))))
       (let ((text (motion-line-string 'x)))
         (should (equal text "50%%"))
         (dotimes (i (length text))
           (should (eq (get-text-property i 'face text) 'bold))
           (should (equal (get-text-property i 'display text) image))))))))

(ert-deftest motion-line-test-replacement-is-atomic ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("good")))
     (should-error
      (motion-line-play 'x (motion-line-clip 1 (lambda (_) (error "bad")))))
     (should (equal (motion-line-string 'x) "good"))
     (motion-line-play 'x (motion-line-frames '("new")))
     (should (= (length motion-line--players) 1))
     (should (= (length motion-line--buffers) 1))
     (should (equal (motion-line-string 'x) "new")))))

(ert-deftest motion-line-test-error-isolation ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play
      'bad (motion-line-clip 3 (lambda (seconds)
                                       (if (> seconds 0) (error "broken") "ok"))))
     (motion-line-play 'good (motion-line-frames '("A" "B") 1))
     (let (report)
       (cl-letf (((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (setq report (apply #'format format-string args)))))
         (motion-line-test--tick 101))
       (should (string-match-p "bad: broken" report)))
     (should-not (plist-get (alist-get 'bad motion-line--players) :playing))
     (should (equal (motion-line-string 'good) "B"))
     (should (timerp motion-line--timer)))))

(ert-deftest motion-line-test-buffer-ownership-and-cleanup ()
  (motion-line-test--run
   (lambda ()
     (let ((clip (motion-line-frames '("A" "B") 1))
           (other (generate-new-buffer " *animation-test*")))
       (unwind-protect
           (progn
             (motion-line-play 'x clip)
             (with-current-buffer other
               (motion-line-play 'x clip :direction 'reverse)
               (should (equal (motion-line-string 'x) "B")))
             (should (= (length motion-line--buffers) 2))
             (should (equal (motion-line-string 'x) "A"))
             (motion-line-stop 'x)
             (should (equal (motion-line-string 'x) ""))
             (should (timerp motion-line--timer))
             (kill-buffer other)
             (should-not motion-line--buffers)
             (should-not motion-line--timer))
         (when (buffer-live-p other) (kill-buffer other)))))))

(ert-deftest motion-line-test-controls-do-not-postpone-other-players ()
  (motion-line-test--run
   (lambda ()
     (let ((clip (motion-line-frames '("A" "B") 1)))
       (motion-line-play 'x clip)
       (let ((deadline (timer--time motion-line--timer)))
         (with-temp-buffer
           (dotimes (_ 10)
             (motion-line-play 'other clip)
             (motion-line-pause 'other)
             (motion-line-resume 'other)
             (motion-line-stop 'other)
             (motion-line-stop 'already-idle))
           (should (equal (timer--time motion-line--timer) deadline)))
         (should (equal (timer--time motion-line--timer) deadline)))
       (motion-line-test--tick 101)
       (should (equal (motion-line-string 'x) "B"))
       (should (= (cl-count #'motion-line--tick timer-list
                            :key #'timer--function)
                  1))))))

(ert-deftest motion-line-test-major-mode-cleanup ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A")))
     (text-mode)
     (should-not motion-line--players)
     (should-not motion-line--buffers)
     (should-not motion-line--timer))))

(ert-deftest motion-line-test-control-error-preserves-state ()
  (motion-line-test--run
   (lambda ()
     (let ((broken nil))
       (motion-line-play
        'x (motion-line-clip
            3 (lambda (seconds)
                (if broken (error "broken") (format "%.1f" seconds)))))
       (motion-line-pause 'x)
       (setq broken t)
       (should-error (motion-line-resume 'x))
       (should-not (plist-get (alist-get 'x motion-line--players) :playing))
       (should-error (motion-line-seek 'x 2))
       (should (= (plist-get (alist-get 'x motion-line--players) :offset) 0))
       (should-not motion-line--timer)
       (setq broken nil)
       (motion-line-resume 'x)
       (motion-line-test--tick 101)
       (should (equal (motion-line-string 'x) "1.0"))))))

(ert-deftest motion-line-test-redisplay-callback-and-playing-state ()
  (motion-line-test--run
   (lambda ()
     (let ((owner (current-buffer)) (calls 0))
       (should-not (motion-line-playing-p 'x))
       (setq-local motion-line-redisplay-function
                   (lambda ()
                     (should (eq owner (current-buffer)))
                     (cl-incf calls)))
       (motion-line-play 'x (motion-line-frames '("A" "B") 1))
       (should (motion-line-playing-p 'x))
       (with-temp-buffer (motion-line-test--tick 101))
       (should (= calls 1))
       (should (equal (motion-line-string 'x) "B"))
       (motion-line-pause 'x)
       (should-not (motion-line-playing-p 'x))
       (should-not motion-line--timer)))))

(ert-deftest motion-line-test-sequence-offsets ()
  (let* ((a (motion-line-frames '("a0" "a1") 1))
         (b (motion-line-frames '("b0" "b1") 1))
         (sequence (motion-line-sequence a b)))
    (should (= (plist-get sequence :duration) 4))
    (should (equal (motion-line-sample sequence 1) "a1"))
    (should (equal (motion-line-sample sequence 2) "b0"))
    (should (equal (motion-line-sample sequence 3) "b1"))
    (should (equal (motion-line-sample sequence 9) "b1"))))

(ert-deftest motion-line-test-seek-preserves-running ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "B" "C") 1))
     (setq motion-line-test--now 100.2)
     (motion-line-seek 'x 1.5)
     (should (motion-line-playing-p 'x))
     (should (equal (motion-line-string 'x) "B"))
     (should (timerp motion-line--timer))
     (motion-line-test--tick 100.7)
     (should (equal (motion-line-string 'x) "C")))))

(ert-deftest motion-line-test-seek-clamps-negative ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "B") 1))
     (motion-line-pause 'x)
     (motion-line-seek 'x -5)
     (should (equal (motion-line-string 'x) "A"))
     (should (= (plist-get (alist-get 'x motion-line--players) :offset)
                0)))))

(ert-deftest motion-line-test-backward-clock-clamps ()
  (motion-line-test--run
   (lambda ()
     (motion-line-play 'x (motion-line-frames '("A" "B") 1))
     (motion-line-test--tick 99.5)
     (should (equal (motion-line-string 'x) "A")))))

(ert-deftest motion-line-test-interval-clamping ()
  (motion-line-test--run
   (lambda ()
     (dolist (case '((0.001 . 0.01) (0.5 . 0.5) (0 . 0.05) (-1 . 0.05)
                     ("fast" . 0.05) (0.0e+NaN . 0.05)))
       (let ((motion-line-interval (car case))
             (seen nil))
         (cl-letf (((symbol-function 'run-at-time)
                    (lambda (time &rest _) (setq seen time) nil)))
           (motion-line-play 'x (motion-line-frames '("A")))
           (should (equal seen (cdr case)))))))))

(ert-deftest motion-line-test-cached-text-is-owned ()
  (motion-line-test--run
   (lambda ()
     (let ((shared (copy-sequence "AB")))
       (motion-line-play 'x (motion-line-clip 1 (lambda (_) shared)))
       (aset shared 0 ?Z)
       (should (equal (motion-line-string 'x) "AB"))))))

(ert-deftest motion-line-test-frame-text-is-owned ()
  (let* ((frame (copy-sequence "AB"))
         (clip (motion-line-frames (list frame))))
    (aset frame 0 ?Z)
    (should (equal (motion-line-sample clip 0) "AB"))))

(provide 'motion-line-test)
;;; motion-line-test.el ends here
