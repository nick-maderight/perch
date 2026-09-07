;;; perch-dictate-test.el --- Tests for Perch dictation -*- lexical-binding: t; -*-

(require 'ert)
(require 'perch-dictate)

(defconst perch-dictate-test--directory
  (file-name-directory
   (expand-file-name (or load-file-name buffer-file-name default-directory)))
  "Directory containing the Perch test file.")

(defun perch-dictate-test--event (id text final)
  "Build a transcript event with ID, TEXT, and FINAL."
  `((event . "transcript")
    (id . ,id)
    (text . ,text)
    (final . ,final)))

(defmacro perch-dictate-test--with-buffer (&rest body)
  "Run BODY with a fresh buffer configured as the voice target."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((perch-dictate--target-buffer (current-buffer))
           (perch-dictate-speech-final-hook nil))
       (perch-dictate-move-here)
       (unwind-protect
           (progn ,@body)
         (perch-dictate-clear-context-overlay)))))

(ert-deftest perch-dictate-interim-then-final ()
  (perch-dictate-test--with-buffer
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "hello wor" nil))
    (should perch-dictate--interim-overlay)
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "hello world" t))
    (should (equal (buffer-string) "hello world "))
    (should-not perch-dictate--interim-overlay)))

(ert-deftest perch-dictate-keeps-separate-utterances ()
  (perch-dictate-test--with-buffer
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "hello" t))
    (perch-dictate--handle-event
     (perch-dictate-test--event 2 "world" t))
    (should (equal (buffer-string) "hello world "))))

(ert-deftest perch-dictate-runs-final-hook-once ()
  (let ((calls 0))
    (perch-dictate-test--with-buffer
      (setq perch-dictate-speech-final-hook
            (list (lambda () (setq calls (1+ calls)))))
      (perch-dictate--handle-event
       (perch-dictate-test--event 1 "draft" nil))
      (should (= calls 0))
      (perch-dictate--handle-event
       (perch-dictate-test--event 1 "final" t))
      (should (= calls 1))
      (perch-dictate--handle-event
       (perch-dictate-test--event 2 "second" t))
      (should (= calls 2)))))

(ert-deftest perch-dictate-interim-at-point-min ()
  (perch-dictate-test--with-buffer
    (should (= (point-min) (point-max)))
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "hello" nil))
    (should (equal (buffer-string) "hello "))))

(ert-deftest perch-dictate-user-text-before-voice-cursor ()
  (perch-dictate-test--with-buffer
    (insert "existing")
    (goto-char (point-max))
    (perch-dictate-move-here)
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "draft" nil))
    (goto-char (point-min))
    (insert "prefix ")
    (perch-dictate--handle-event
     (perch-dictate-test--event 1 "final" t))
    (should (equal (buffer-string) "prefix existingfinal "))))

(ert-deftest perch-dictate-integration-file-input ()
  :tags '(:integration)
  (unless (executable-find "uv")
    (ert-skip "uv is not installed"))
  (let ((fixture (expand-file-name "resources/hello-world.wav"
                                  perch-dictate-test--directory))
        (deadline (+ (float-time) 300)))
    (with-temp-buffer
      (let ((perch-dictate-server-args (list "--input" fixture)))
        (unwind-protect
            (progn
              (perch-dictate-start)
              (while (and (process-live-p perch-dictate--process)
                          (< (float-time) deadline))
                (accept-process-output perch-dictate--process 0.5))
              (let ((text (downcase (buffer-string))))
                (setq text (replace-regexp-in-string "[[:punct:]]" "" text))
                (should (string-match-p "hello world" text))
                (should (string-match-p "local dictation" text))))
          (when (process-live-p perch-dictate--process)
            (perch-dictate-stop))
          (perch-dictate-clear-context-overlay))))))

;;; perch-dictate-test.el ends here
