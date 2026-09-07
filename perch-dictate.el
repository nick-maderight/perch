;;; perch-dictate.el --- Local dictation for Emacs with NVIDIA Parakeet -*- lexical-binding: t; -*-

;; Copyright (c) 2024 Abhinav Tushar
;; Copyright (c) 2026 Nick Wang

;; Author: Nick Wang
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: speech
;; URL: https://github.com/nick-maderight/perch
;; Forked from esi-dictate by Abhinav Tushar <abhinav@lepisma.xyz>

;;; Commentary:

;; Perch places a voice cursor in an Emacs buffer and inserts local dictation.
;; It runs NVIDIA Parakeet on the machine through parakeet-mlx.
;; Optional LLM cleanup can revise the current voice context after an utterance.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'llm nil t)

(declare-function make-llm-chat-prompt "llm")
(declare-function llm-chat-prompt-append-response "llm")
(declare-function llm-chat-async "llm")

(defgroup perch-dictate nil
  "Local dictation with NVIDIA Parakeet."
  :group 'applications
  :prefix "perch-dictate-")

(defconst perch-dictate--source-directory
  (file-name-directory
   (expand-file-name (or load-file-name buffer-file-name default-directory)))
  "Directory containing the Perch Emacs package.")

(defcustom perch-dictate-server-command
  (list "uv" "run" "--script"
        (expand-file-name "perch_server.py" perch-dictate--source-directory))
  "Command used to start the local Perch transcription server."
  :group 'perch-dictate
  :type '(repeat string))

(defcustom perch-dictate-server-args nil
  "Additional arguments passed to the local transcription server."
  :group 'perch-dictate
  :type '(repeat string))

(defcustom perch-dictate-model "mlx-community/parakeet-tdt-0.6b-v3"
  "Parakeet model repository passed to the transcription server."
  :group 'perch-dictate
  :type 'string)

(defcustom perch-dictate-utterance-end-ms 800
  "Silence duration that ends an utterance, in milliseconds."
  :group 'perch-dictate
  :type 'integer)

(defcustom perch-dictate-input-device nil
  "Input device passed to the transcription server.

A nil value uses the system default input device."
  :group 'perch-dictate
  :type '(choice (const :tag "System default" nil) string))

(defcustom perch-dictate-llm-provider nil
  "LLM provider used for optional voice context corrections."
  :group 'perch-dictate
  :type 'sexp)

(defcustom perch-dictate-speech-final-hook nil
  "Hook run after the server finalizes a speech utterance."
  :group 'perch-dictate
  :type 'hook)

(defcustom perch-dictate-cursor "⤳"
  "String displayed at the voice cursor."
  :group 'perch-dictate
  :type 'string)

(defcustom perch-dictate-llm-prompt
  "You are a dictation assistant, you will be given transcript by the user with speech disfluencies, minor mistakes, and edits and you have to return a corrected transcript. The user might give you their stream of consciousness and you have to ensure that you correctly identify a request to edit and don't misfire. You don't have to generate any new information, just ensure fixes in spoken transcripts and edits as asked."
  "System prompt for the optional LLM editor."
  :group 'perch-dictate
  :type 'string)

(defcustom perch-dictate-fix-examples
  (list (cons "I wan to write about umm something related to food. My name is name is Abhinav"
              "I want to write about umm something related to food. My name is Abhinav.")
        (cons "Okay we will start. Let's write something about chairs. No not chairs, make it tables."
              "Let's write something about tables.")
        (cons "I want to write something that's difficult to transcribe and then try correcting that. Write my name as abcd. No separate the letters with . please"
              "I want to write something that's difficult to transcribe and then try correcting that. Write my name as a.b.c.d.")
        (cons "hi perch, what are you doing? It's p e r c h."
              "hi Perch, what are you doing?"))
  "Example inputs and outputs for few-shot voice context cleanup."
  :group 'perch-dictate
  :type '(repeat (cons string string)))

(defface perch-dictate-intermittent-face
  '((t (:inherit font-lock-comment-face)))
  "Face for transcript text that may change during recognition."
  :group 'perch-dictate)

(defface perch-dictate-context-face
  '((t (:inherit link)))
  "Face for the voice context sent to the optional LLM."
  :group 'perch-dictate)

(defface perch-dictate-cursor-face
  '((t (:inherit default)))
  "Face for the voice cursor."
  :group 'perch-dictate)

(defvar perch-dictate-mode-map
  (make-sparse-keymap)
  "Keymap for `perch-dictate-mode'.")

(defvar-local perch-dictate-context-overlay nil
  "Overlay whose end marks the next dictation insertion position.")

(defvar-local perch-dictate--interim-overlay nil
  "Overlay for the current interim transcript in this buffer.")

(defvar perch-dictate--process nil
  "Process running the local Perch transcription server.")

(defvar perch-dictate--target-buffer nil
  "Buffer that receives events from `perch-dictate--process'.")

(define-minor-mode perch-dictate-mode
  "Toggle local Perch dictation mode."
  :init-value nil
  :lighter " Perch"
  :keymap perch-dictate-mode-map)

(defun perch-dictate--write-fix (edited-content)
  "Replace the active voice context with EDITED-CONTENT."
  (if (not (overlayp perch-dictate-context-overlay))
      (message "[perch] The voice context is no longer active.")
    (let ((beg-pos (overlay-start perch-dictate-context-overlay))
          (end-pos (overlay-end perch-dictate-context-overlay))
          (past-point (point)))
      (delete-region beg-pos end-pos)
      (goto-char beg-pos)
      (insert edited-content)
      ;; Replicate save-excursion while replacing the full context.
      (let ((current-point (point)))
        (if (<= past-point beg-pos)
            (goto-char past-point)
          (if (<= past-point end-pos)
              (goto-char (min past-point current-point))
            (goto-char (+ current-point (- past-point end-pos)))))
        (move-overlay perch-dictate-context-overlay beg-pos current-point)))))

(defun perch-dictate--call-llm (content)
  "Ask the configured LLM to clean up dictation CONTENT."
  (let ((prompt (make-llm-chat-prompt
                 :context perch-dictate-llm-prompt
                 :examples perch-dictate-fix-examples)))
    (llm-chat-prompt-append-response prompt content)
    (llm-chat-async
     perch-dictate-llm-provider
     prompt
     #'perch-dictate--write-fix
     (lambda (err err-message)
       (message "[perch] LLM error %s: %s" err err-message)))))

(defun perch-dictate-fix-context ()
  "Use the configured LLM to fix the current voice context."
  (interactive)
  (unless perch-dictate-llm-provider
    (user-error "[perch] Configure perch-dictate-llm-provider before fixing context"))
  (unless (featurep 'llm)
    (user-error "[perch] Load the optional llm package before fixing context"))
  (unless (overlayp perch-dictate-context-overlay)
    (user-error "[perch] No active voice context to fix"))
  (let ((beg-pos (overlay-start perch-dictate-context-overlay))
        (end-pos (overlay-end perch-dictate-context-overlay)))
    (perch-dictate--call-llm
     (buffer-substring-no-properties beg-pos end-pos))))

(defun perch-dictate-make-context-overlay ()
  "Create and return a voice context overlay."
  (let ((overlay (if (region-active-p)
                     (make-overlay (region-beginning) (region-end) nil nil t)
                   (make-overlay (point) (point) nil nil t))))
    (overlay-put overlay 'face 'perch-dictate-context-face)
    (overlay-put overlay 'after-string
                 (propertize perch-dictate-cursor
                             'face 'perch-dictate-cursor-face))
    overlay))

(defun perch-dictate-clear-context-overlay ()
  "Delete the voice context and any current interim transcript overlay."
  (when (overlayp perch-dictate--interim-overlay)
    (delete-overlay perch-dictate--interim-overlay))
  (setq perch-dictate--interim-overlay nil)
  (when (overlayp perch-dictate-context-overlay)
    (delete-overlay perch-dictate-context-overlay))
  (setq perch-dictate-context-overlay nil))

(defun perch-dictate-move-here ()
  "Move the voice cursor to point or the active region."
  (interactive)
  (perch-dictate-clear-context-overlay)
  (setq perch-dictate-context-overlay
        (perch-dictate-make-context-overlay)))

(defun perch-dictate-insert (item)
  "Insert transcript ITEM at the voice cursor.

ITEM is an alist with `id', `text', and `final' fields."
  (let ((target perch-dictate--target-buffer))
    (if (not (buffer-live-p target))
        (perch-dictate-stop)
      (with-current-buffer target
        (unless (and (overlayp perch-dictate-context-overlay)
                     (eq (overlay-buffer perch-dictate-context-overlay)
                         target))
          (perch-dictate-move-here))
        (let* ((overlay perch-dictate-context-overlay)
               (id (alist-get 'id item))
               (text (or (alist-get 'text item) ""))
               (final (alist-get 'final item))
               (end-pos (overlay-end overlay)))
          (when (and (> end-pos (point-min))
                     (equal id
                            (get-text-property
                             (1- end-pos) 'perch-dictate-item-id)))
            (let ((start-pos
                   (get-text-property
                    (1- end-pos) 'perch-dictate-start)))
              (when start-pos
                (delete-region start-pos end-pos))))
          (let ((insertion-pos (overlay-end overlay))
                insertion-end)
            (save-excursion
              (goto-char insertion-pos)
              (insert text " ")
              (setq insertion-end (point)))
            (put-text-property insertion-pos insertion-end
                               'perch-dictate-item-id id)
            (put-text-property insertion-pos insertion-end
                               'perch-dictate-start (copy-marker insertion-pos))
            (if final
                (progn
                  (when (overlayp perch-dictate--interim-overlay)
                    (delete-overlay perch-dictate--interim-overlay))
                  (setq perch-dictate--interim-overlay nil)
                  (run-hooks 'perch-dictate-speech-final-hook))
              (if (and (overlayp perch-dictate--interim-overlay)
                       (eq (overlay-buffer perch-dictate--interim-overlay)
                           target))
                  (move-overlay perch-dictate--interim-overlay
                                insertion-pos insertion-end)
                (when (overlayp perch-dictate--interim-overlay)
                  (delete-overlay perch-dictate--interim-overlay))
                (setq perch-dictate--interim-overlay
                      (make-overlay insertion-pos insertion-end target)))
              (overlay-put perch-dictate--interim-overlay
                           'face 'perch-dictate-intermittent-face))))))))

(defun perch-dictate--handle-event (item)
  "Handle one parsed server event represented by alist ITEM."
  (let ((event (alist-get 'event item)))
    (cond
     ((equal event "ready")
      (message "[perch] Ready. Voice cursor placed at point.")
      (if (not (buffer-live-p perch-dictate--target-buffer))
          (perch-dictate-stop)
        (with-current-buffer perch-dictate--target-buffer
          (unless (overlayp perch-dictate-context-overlay)
            (perch-dictate-move-here)))))
     ((equal event "transcript")
      (perch-dictate-insert item))
     ((equal event "status")
      (message "[perch] %s" (or (alist-get 'message item) "")))
     ((equal event "error")
      (message "[perch] server error: %s" (or (alist-get 'message item) "")))
     ((equal event "done")
      (message "[perch] Server finished."))
     (event
      (message "[perch] Unknown server event: %s" event)))))

(defun perch-dictate--filter (process string)
  "Parse complete JSON lines received from PROCESS."
  (let ((existing (concat (or (process-get process 'accumulated-output) "")
                          string)))
    (while (string-match "\n" existing)
      (let ((line (substring existing 0 (match-beginning 0))))
        (setq existing (substring existing (match-end 0)))
        (unless (string= line "")
          (condition-case err
              (perch-dictate--handle-event
               (json-parse-string line
                                  :object-type 'alist
                                  :false-object nil
                                  :null-object nil))
            (error
             (message "[perch] Invalid server output: %s"
                      (error-message-string err)))))))
    (process-put process 'accumulated-output existing)))

(defun perch-dictate--sentinel (process event)
  "Handle PROCESS termination described by EVENT."
  (when (and (eq process perch-dictate--process)
             (memq (process-status process) '(exit signal)))
    (let ((target perch-dictate--target-buffer))
      (setq perch-dictate--process nil
            perch-dictate--target-buffer nil)
      (when (buffer-live-p target)
        (with-current-buffer target
          (when perch-dictate-mode
            (message "[perch] Server exited: %s" (string-trim event)))
          (perch-dictate-mode -1)
          (perch-dictate-clear-context-overlay))))))

(defun perch-dictate--build-command ()
  "Build the command and arguments for the local transcription server."
  (append perch-dictate-server-command
          (list "--model" perch-dictate-model
                "--utterance-end-ms"
                (number-to-string perch-dictate-utterance-end-ms))
          (when perch-dictate-input-device
            (list "--device" perch-dictate-input-device))
          perch-dictate-server-args))

(defun perch-dictate--clear-process ()
  "Stop the current server and clear its target buffer state."
  (let ((process perch-dictate--process)
        (target perch-dictate--target-buffer))
    (setq perch-dictate--process nil
          perch-dictate--target-buffer nil)
    (when (process-live-p process)
      (delete-process process))
    (when (buffer-live-p target)
      (with-current-buffer target
        (perch-dictate-mode -1)
        (perch-dictate-clear-context-overlay)))))

;;;###autoload
(defun perch-dictate-start ()
  "Start local Parakeet dictation in the current buffer."
  (interactive)
  (perch-dictate--clear-process)
  (setq perch-dictate--target-buffer (current-buffer))
  (with-current-buffer perch-dictate--target-buffer
    (perch-dictate-mode 1))
  (condition-case err
      (setq perch-dictate--process
            (make-process
             :name "perch-dictate"
             :buffer " *perch-dictate*"
             :stderr (get-buffer-create " *perch-dictate-stderr*")
             :command (perch-dictate--build-command)
             :filter #'perch-dictate--filter
             :sentinel #'perch-dictate--sentinel
             :coding 'utf-8
             :noquery t))
    (error
     (perch-dictate--clear-process)
     (signal (car err) (cdr err))))
  (message "[perch] Loading Parakeet model ..."))

(defun perch-dictate-stop ()
  "Stop local Parakeet dictation and remove its overlays."
  (interactive)
  (let ((target perch-dictate--target-buffer))
    (perch-dictate--clear-process)
    (when (or (null target) (eq target (current-buffer)))
      (perch-dictate-mode -1)
      (perch-dictate-clear-context-overlay)))
  (message "[perch] Stopped dictation mode."))

(defun perch-dictate-toggle ()
  "Start dictation when stopped, or stop it when running."
  (interactive)
  (if (process-live-p perch-dictate--process)
      (perch-dictate-stop)
    (perch-dictate-start)))

(provide 'perch-dictate)

;;; perch-dictate.el ends here
