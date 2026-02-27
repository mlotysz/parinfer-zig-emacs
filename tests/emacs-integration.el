;;; emacs-integration.el --- Integration tests for parinfer-rust Zig module -*- lexical-binding: t; -*-

;; Run with: emacs --batch -l tests/emacs-integration.el

(require 'cl-lib)

(defvar test-passed 0)
(defvar test-failed 0)
(defvar test-errors nil)

(defmacro test-assert (name &rest body)
  "Run BODY as a test named NAME. BODY should signal an error on failure."
  `(condition-case err
       (progn
         ,@body
         (setq test-passed (1+ test-passed))
         (message "  PASS: %s" ,name))
     (error
      (setq test-failed (1+ test-failed))
      (push (cons ,name (error-message-string err)) test-errors)
      (message "  FAIL: %s -- %s" ,name (error-message-string err)))))

;; Load the module
(message "=== Parinfer Emacs Integration Tests ===")
(message "Loading module from zig-out/lib/libparinfer_rust.so...")

(let ((lib-path (expand-file-name "zig-out/lib/libparinfer_rust.so"
                                   (file-name-directory
                                    (directory-file-name
                                     (file-name-directory load-file-name))))))
  (unless (file-exists-p lib-path)
    (message "FATAL: Library not found at %s" lib-path)
    (kill-emacs 1))
  (module-load lib-path))

(message "Module loaded successfully.")

;; Test 1: Version
(test-assert "parinfer-rust-version returns a string"
  (let ((ver (parinfer-rust-version)))
    (unless (stringp ver)
      (error "Expected string, got %S" ver))
    (unless (string-match-p "^[0-9]+\\.[0-9]+\\.[0-9]+$" ver)
      (error "Expected version format X.Y.Z, got %S" ver))
    (message "    version = %s" ver)))

;; Test 2: Make option and get/set
(test-assert "make-option creates options object"
  (let ((opts (parinfer-rust-make-option)))
    (unless opts
      (error "make-option returned nil"))))

(test-assert "get-option returns nil for unset cursor"
  (let* ((opts (parinfer-rust-make-option))
         (val (parinfer-rust-get-option opts :cursor-x)))
    (unless (eq val nil)
      (error "Expected nil, got %S" val))))

(test-assert "set-option and get-option round-trip"
  (let ((opts (parinfer-rust-make-option)))
    (parinfer-rust-set-option opts :cursor-x 5)
    (let ((val (parinfer-rust-get-option opts :cursor-x)))
      (unless (equal val 5)
        (error "Expected 5, got %S" val)))))

(test-assert "set-option boolean fields"
  (let ((opts (parinfer-rust-make-option)))
    (parinfer-rust-set-option opts :force-balance t)
    (let ((val (parinfer-rust-get-option opts :force-balance)))
      (unless (eq val t)
        (error "Expected t, got %S" val)))))

;; Test 3: Changes API
(test-assert "make-changes creates a change list"
  (let ((changes (parinfer-rust-make-changes)))
    (unless changes
      (error "make-changes returned nil"))))

(test-assert "new-change creates a change"
  (let ((change (parinfer-rust-new-change 0 5 "old" "new")))
    (unless change
      (error "new-change returned nil"))))

(test-assert "add-change adds to change list"
  (let ((changes (parinfer-rust-make-changes))
        (change (parinfer-rust-new-change 0 5 "old" "new")))
    (parinfer-rust-add-change changes change)))

;; Test 4: Request and Execute - indent mode
(test-assert "indent mode: basic paren inference"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(def foo\n  bar" opts))
         (result (parinfer-rust-execute req))
         (text (parinfer-rust-get-answer result :text))
         (success (parinfer-rust-get-answer result :success)))
    (unless (eq success t)
      (error "Expected success=t, got %S" success))
    (unless (string= text "(def foo\n  bar)")
      (error "Expected closing paren, got %S" text))))

(test-assert "indent mode: multiple parens"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(let [x 1]\n  (+ x 2" opts))
         (result (parinfer-rust-execute req))
         (text (parinfer-rust-get-answer result :text))
         (success (parinfer-rust-get-answer result :success)))
    (unless (eq success t)
      (error "Expected success=t, got %S" success))
    (unless (string= text "(let [x 1]\n  (+ x 2))")
      (error "Expected closing parens, got %S" text))))

;; Test 5: Paren mode
(test-assert "paren mode: indentation inference"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "paren" "(def foo\nbar)" opts))
         (result (parinfer-rust-execute req))
         (text (parinfer-rust-get-answer result :text))
         (success (parinfer-rust-get-answer result :success)))
    (unless (eq success t)
      (error "Expected success=t, got %S" success))
    (unless (string= text "(def foo\n bar)")
      (error "Expected indentation, got %S" text))))

;; Test 6: Smart mode
(test-assert "smart mode: basic"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "smart" "(def foo\n  bar" opts))
         (result (parinfer-rust-execute req))
         (text (parinfer-rust-get-answer result :text))
         (success (parinfer-rust-get-answer result :success)))
    (unless (eq success t)
      (error "Expected success=t, got %S" success))
    (unless (string= text "(def foo\n  bar)")
      (error "Expected text, got %S" text))))

;; Test 7: Error handling
(test-assert "paren mode: unmatched close paren reports error"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "paren" ")" opts))
         (result (parinfer-rust-execute req))
         (success (parinfer-rust-get-answer result :success))
         (err (parinfer-rust-get-answer result :error)))
    (unless (eq success nil)
      (error "Expected success=nil, got %S" success))
    (unless err
      (error "Expected error, got nil"))))

;; Test 8: new-options with keyword args
(test-assert "new-options creates options with cursor info"
  (let* ((changes (parinfer-rust-make-changes))
         (old-opts (parinfer-rust-make-option))
         (opts (parinfer-rust-new-options 5 3 nil old-opts changes)))
    (let ((cx (parinfer-rust-get-option opts :cursor-x))
          (cl (parinfer-rust-get-option opts :cursor-line)))
      (unless (equal cx 5)
        (error "Expected cursor-x=5, got %S" cx))
      (unless (equal cl 3)
        (error "Expected cursor-line=3, got %S" cl)))))

;; Test 9: print functions don't crash
(test-assert "print-options returns a string"
  (let* ((opts (parinfer-rust-make-option))
         (s (parinfer-rust-print-options opts)))
    (unless (stringp s)
      (error "Expected string, got %S" s))))

(test-assert "print-changes returns a string"
  (let* ((changes (parinfer-rust-make-changes))
         (s (parinfer-rust-print-changes changes)))
    (unless (stringp s)
      (error "Expected string, got %S" s))))

(test-assert "print-request returns a string"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(foo" opts))
         (s (parinfer-rust-print-request req)))
    (unless (stringp s)
      (error "Expected string, got %S" s))))

(test-assert "print-answer returns a string"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(foo" opts))
         (result (parinfer-rust-execute req))
         (s (parinfer-rust-print-answer result)))
    (unless (stringp s)
      (error "Expected string, got %S" s))))

;; Test 10: Answer accessors
(test-assert "get-answer :tab-stops returns a list"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(foo\n  bar" opts))
         (result (parinfer-rust-execute req))
         (stops (parinfer-rust-get-answer result :tab-stops)))
    (unless (listp stops)
      (error "Expected list, got %S" stops))))

(test-assert "get-answer :paren-trails returns a list"
  (let* ((opts (parinfer-rust-make-option))
         (req (parinfer-rust-make-request "indent" "(foo\n  bar" opts))
         (result (parinfer-rust-execute req))
         (trails (parinfer-rust-get-answer result :paren-trails)))
    (unless (listp trails)
      (error "Expected list, got %S" trails))))

;; Summary
(message "")
(message "=== Results: %d passed, %d failed ===" test-passed test-failed)
(when test-errors
  (message "Failures:")
  (dolist (e (reverse test-errors))
    (message "  - %s: %s" (car e) (cdr e))))

(kill-emacs (if (> test-failed 0) 1 0))
