(defpackage :test-util
  (:use :cl :sb-ext)
  (:export #:with-test #:report-test-status #:*failures*
           #:really-invoke-debugger
           #:*break-on-failure* #:*break-on-expected-failure*
           #:make-kill-thread #:make-join-thread))

(in-package :test-util)

(defvar *test-count* 0)
(defvar *test-file* nil)
(defvar *failures* nil)
(defvar *break-on-failure* nil)
(defvar *break-on-expected-failure* nil)

(defvar *threads-to-kill*)
(defvar *threads-to-join*)

#+sb-thread
(defun make-kill-thread (&rest args)
  (let ((thread (apply #'sb-thread:make-thread args)))
    (when (boundp '*threads-to-kill*)
      (push thread *threads-to-kill*))
    thread))

#+sb-thread
(defun make-join-thread (&rest args)
  (let ((thread (apply #'sb-thread:make-thread args)))
    (when (boundp '*threads-to-join*)
      (push thread *threads-to-join*))
    thread))

(defun log-msg (&rest args)
  (format *trace-output* "~&::: ")
  (apply #'format *trace-output* args)
  (terpri *trace-output*)
  (force-output *trace-output*))

(defmacro with-test ((&key fails-on broken-on skipped-on name)
                     &body body)
  (let ((block-name (gensym))
        #+sb-thread (threads (gensym "THREADS")))
    `(progn
       (start-test)
       (cond
         ((broken-p ,broken-on)
          (fail-test :skipped-broken ',name "Test broken on this platform"))
         ((skipped-p ,skipped-on)
          (fail-test :skipped-disabled ',name "Test disabled for this combination of platform and features"))
         (t
          (let (#+sb-thread (,threads (sb-thread:list-all-threads))
                (*threads-to-join* nil)
                (*threads-to-kill* nil))
            (block ,block-name
              (handler-bind ((error (lambda (error)
                                      (if (expected-failure-p ,fails-on)
                                          (fail-test :expected-failure ',name error)
                                          (fail-test :unexpected-failure ',name error))
                                      (return-from ,block-name))))
                (progn
                  (log-msg "Running ~S" ',name)
                  ,@body
                  #+sb-thread
                  (let ((any-leftover nil))
                    (dolist (thread *threads-to-join*)
                      (ignore-errors (sb-thread:join-thread thread)))
                    (dolist (thread *threads-to-kill*)
                      (ignore-errors (sb-thread:terminate-thread thread)))
                    (setf ,threads (union (union *threads-to-kill*
                                                 *threads-to-join*)
                                          ,threads))
                    #+(and sb-safepoint-strictly (not win32))
                    (dolist (thread (sb-thread:list-all-threads))
                      (when (typep thread 'sb-thread:signal-handling-thread)
                        (ignore-errors (sb-thread:join-thread thread))))
                    (dolist (thread (sb-thread:list-all-threads))
                      (unless (or (not (sb-thread:thread-alive-p thread))
                                  (eql thread sb-thread:*current-thread*)
                                  (member thread ,threads)
                                  (sb-thread:thread-emphemeral-p thread))
                        (setf any-leftover thread)
                        (ignore-errors (sb-thread:terminate-thread thread))))
                    (when any-leftover
                      (fail-test :leftover-thread ',name any-leftover)
                      (return-from ,block-name)))
                  (if (expected-failure-p ,fails-on)
                      (fail-test :unexpected-success ',name nil)
                      (log-msg "Success ~S" ',name)))))))))))

(defun report-test-status ()
  (with-standard-io-syntax
      (with-open-file (stream "test-status.lisp-expr"
                              :direction :output
                              :if-exists :supersede)
        (format stream "~s~%" *failures*))))

(defun start-test ()
  (unless (eq *test-file* *load-pathname*)
    (setf *test-file* *load-pathname*)
    (setf *test-count* 0))
  (incf *test-count*))

(defun really-invoke-debugger (condition)
  (with-simple-restart (continue "Continue")
    (let ((*invoke-debugger-hook* *invoke-debugger-hook*))
      (enable-debugger)
      (invoke-debugger condition))))

(defun fail-test (type test-name condition)
  (if (stringp condition)
      (log-msg "~@<~A ~S ~:_~A~:>"
               type test-name condition)
      (log-msg "~@<~A ~S ~:_due to ~S: ~4I~:_\"~A\"~:>"
               type test-name condition condition))
  (push (list type *test-file* (or test-name *test-count*))
        *failures*)
  (unless (stringp condition)
    (when (or (and *break-on-failure*
                   (not (eq type :expected-failure)))
              *break-on-expected-failure*)
      (really-invoke-debugger condition))))

(defun expected-failure-p (fails-on)
  (sb-impl::featurep fails-on))

(defun broken-p (broken-on)
  (sb-impl::featurep broken-on))

(defun skipped-p (skipped-on)
  (sb-impl::featurep skipped-on))

(defun test-env ()
  (cons (format nil "SBCL_MACHINE_TYPE=~A" (machine-type))
        (cons (format nil "SBCL_SOFTWARE_TYPE=~A" (software-type))
              (posix-environ))))
