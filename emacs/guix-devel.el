;;; guix-devel.el --- Development tools   -*- lexical-binding: t -*-

;; Copyright © 2015 Alex Kost <alezost@gmail.com>

;; This file is part of GNU Guix.

;; GNU Guix is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Guix is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provides commands useful for developing Guix (or even
;; arbitrary Guile code) with Geiser.

;;; Code:

(require 'guix-guile)
(require 'guix-geiser)
(require 'guix-utils)
(require 'guix-base)

(defgroup guix-devel nil
  "Settings for Guix development utils."
  :group 'guix)

(defgroup guix-devel-faces nil
  "Faces for `guix-devel-mode'."
  :group 'guix-devel
  :group 'guix-faces)

(defface guix-devel-modify-phases-keyword
  '((t :inherit font-lock-preprocessor-face))
  "Face for a `modify-phases' keyword ('delete', 'replace', etc.)."
  :group 'guix-devel-faces)

(defface guix-devel-gexp-symbol
  '((t :inherit font-lock-keyword-face))
  "Face for gexp symbols ('#~', '#$', etc.).
See Info node `(guix) G-Expressions'."
  :group 'guix-devel-faces)

(defcustom guix-devel-activate-mode t
  "If non-nil, then `guix-devel-mode' is automatically activated
in Scheme buffers."
  :type 'boolean
  :group 'guix-devel)

(defun guix-devel-use-modules (&rest modules)
  "Use guile MODULES."
  (apply #'guix-geiser-call "use-modules" modules))

(defun guix-devel-use-module (&optional module)
  "Use guile MODULE in the current Geiser REPL.
MODULE is a string with the module name - e.g., \"(ice-9 match)\".
Interactively, use the module defined by the current scheme file."
  (interactive (list (guix-guile-current-module)))
  (guix-devel-use-modules module)
  (message "Using %s module." module))

(defun guix-devel-copy-module-as-kill ()
  "Put the name of the current guile module into `kill-ring'."
  (interactive)
  (guix-copy-as-kill (guix-guile-current-module)))

(defun guix-devel-setup-repl (&optional repl)
  "Setup REPL for using `guix-devel-...' commands."
  (guix-devel-use-modules "(guix monad-repl)"
                          "(guix scripts)"
                          "(guix store)")
  ;; Without this workaround, the build output disappears.  See
  ;; <https://github.com/jaor/geiser/issues/83> for details.
  (guix-geiser-eval-in-repl
   "(current-build-output-port (current-error-port))"
   repl 'no-history 'no-display))

(defvar guix-devel-repl-processes nil
  "List of REPL processes configured by `guix-devel-setup-repl'.")

(defun guix-devel-setup-repl-maybe (&optional repl)
  "Setup (if needed) REPL for using `guix-devel-...' commands."
  (let ((process (get-buffer-process (or repl (guix-geiser-repl)))))
    (when (and process
               (not (memq process guix-devel-repl-processes)))
      (guix-devel-setup-repl repl)
      (push process guix-devel-repl-processes))))

(defun guix-devel-build-package-definition ()
  "Build a package defined by the current top-level variable definition."
  (interactive)
  (let ((def (guix-guile-current-definition)))
    (guix-devel-setup-repl-maybe)
    (guix-devel-use-modules (guix-guile-current-module))
    (when (or (not guix-operation-confirm)
              (guix-operation-prompt (format "Build '%s'?" def)))
      (guix-geiser-eval-in-repl
       (concat ",run-in-store "
               (guix-guile-make-call-expression
                "build-package" def
                "#:use-substitutes?" (guix-guile-boolean
                                      guix-use-substitutes)
                "#:dry-run?" (guix-guile-boolean guix-dry-run)))))))


;;; Font-lock

(defvar guix-devel-modify-phases-keyword-regexp
  (rx (+ word))
  "Regexp for a 'modify-phases' keyword ('delete', 'replace', etc.).")

(defun guix-devel-modify-phases-font-lock-matcher (limit)
  "Find a 'modify-phases' keyword.
This function is used as a MATCHER for `font-lock-keywords'."
  (ignore-errors
    (down-list)
    (or (re-search-forward guix-devel-modify-phases-keyword-regexp
                           limit t)
        (set-match-data nil))
    (up-list)
    t))

(defun guix-devel-modify-phases-font-lock-pre ()
  "Skip the next sexp, and return the end point of the current list.
This function is used as a PRE-MATCH-FORM for `font-lock-keywords'
to find 'modify-phases' keywords."
  (ignore-errors (forward-sexp))
  (save-excursion (up-list) (point)))

(defvar guix-devel-font-lock-keywords
  `((,(rx (or "#~" "#$" "#$@" "#+" "#+@")) .
     'guix-devel-gexp-symbol)
    (,(guix-guile-keyword-regexp "modify-phases")
     (1 'font-lock-keyword-face)
     (guix-devel-modify-phases-font-lock-matcher
      (guix-devel-modify-phases-font-lock-pre)
      nil
      (0 'guix-devel-modify-phases-keyword nil t))))
  "A list of `font-lock-keywords' for `guix-devel-mode'.")


(defvar guix-devel-keys-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") 'guix-devel-build-package-definition)
    (define-key map (kbd "k") 'guix-devel-copy-module-as-kill)
    (define-key map (kbd "u") 'guix-devel-use-module)
    map)
  "Keymap with subkeys for `guix-devel-mode-map'.")

(defvar guix-devel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c .") guix-devel-keys-map)
    map)
  "Keymap for `guix-devel-mode'.")

;;;###autoload
(define-minor-mode guix-devel-mode
  "Minor mode for `scheme-mode' buffers.

With a prefix argument ARG, enable the mode if ARG is positive,
and disable it otherwise.  If called from Lisp, enable the mode
if ARG is omitted or nil.

When Guix Devel mode is enabled, it provides the following key
bindings:

\\{guix-devel-mode-map}"
  :init-value nil
  :lighter " Guix"
  :keymap guix-devel-mode-map
  (if guix-devel-mode
      (progn
        (setq-local font-lock-multiline t)
        (font-lock-add-keywords nil guix-devel-font-lock-keywords))
    (setq-local font-lock-multiline nil)
    (font-lock-remove-keywords nil guix-devel-font-lock-keywords))
  (when font-lock-mode
    (font-lock-fontify-buffer)))

;;;###autoload
(defun guix-devel-activate-mode-maybe ()
  "Activate `guix-devel-mode' depending on
`guix-devel-activate-mode' variable."
  (when guix-devel-activate-mode
    (guix-devel-mode)))

(provide 'guix-devel)

;;; guix-devel.el ends here
