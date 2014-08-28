;;; -*- lisp -*-
(in-package :asdf)

;; ASDF system definition for loading the Swank server independently
;; of Emacs.
;;
;; Usage:
;;
;;   (asdf:load-system :swank)
;;   (swank:create-server :port PORT) => ACTUAL-PORT
;;
;; (PORT can be zero to mean "any available port".)
;; Then the Swank server is running on localhost:ACTUAL-PORT. You can
;; use `M-x sly-connect' to connect Emacs to it.
;;
;; This code has been placed in the Public Domain.  All warranties
;; are disclaimed.

(defsystem :swank
  :components
  ((:module "lib"
    :components
    ((:module "lisp"
      :serial t
      :components
      ((:file "swank-backend")
       ;; If/when we require ASDF3, we shall use :if-feature instead
       #+(or cmu sbcl scl)
       (:file "swank-source-path-parser")
       #+(or cmu ecl sbcl scl)
       (:file "swank-source-file-cache")
       #+clisp
       (:file "xref")
       #+(or clisp clozure)
       (:file "metering")
       (:module "backend"
        :serial t
        :components (#+allegro
                     (:file "swank-allegro")
                     #+armedbear
                     (:file "swank-abcl")
                     #+clisp
                     (:file "swank-clisp")
                     #+clozure
                     (:file "swank-ccl")
                     #+cmu
                     (:file "swank-cmucl")
                     #+cormanlisp
                     (:file "swank-corman")
                     #+ecl
                     (:file "swank-ecl")
                     #+lispworks
                     (:file "swank-lispworks")
                     #+sbcl
                     (:file "swank-sbcl")
                     #+scl
                     (:file "swank-scl")))
       #+(or sbcl allegro clisp clozure cormanlisp ecl lispworks)
       (:file "swank-gray")
       (:file "swank-match")
       (:file "swank-rpc")
       (:file "swank-ring")
       (:file "swank")))))))

(defmethod perform :after ((o load-op) (c (eql (find-system :swank))))
  (format *error-output* "&SWANK's ASDF loader finished")
  (funcall (read-from-string "swank::init")))


;;; Contrib systems (should probably go into their own file one day)
;;;

(defsystem :swank-util
  :components ((:file "contrib/swank-util")))

(defsystem :swank-arglists
  :components ((:file "contrib/swank-arglists")))

(defsystem :swank-c-p-c
  :components ((:file "contrib/swank-c-p-c")))

(defsystem :swank-fuzzy
  :components ((:file "contrib/swank-fuzzy")))

(defsystem :swank-fancy-inspector
  :components ((:file "contrib/swank-fancy-inspector")))

(defsystem :swank-asdf
  :components ((:file "contrib/swank-asdf")))

(defsystem :swank-package-fu
  :components ((:file "contrib/swank-package-fu")))

(defsystem :swank-hyperdoc
  :components ((:file "contrib/swank-hyperdoc")))

(defsystem :swank-mrepl
  :components ((:file "contrib/swank-mrepl")))

(defsystem :swank-trace-dialog
  :components ((:file "contrib/swank-trace-dialog")))

(defsystem :swank-clipboard
  :components ((:file "contrib/swank-clipboard")))

(defsystem :swank-indentation
  :components ((:file "contrib/swank-indentation")))

(asdf:defsystem :swank-contribs
    :depends-on
  (:swank
   :swank-util :swank-repl
   :swank-c-p-c :swank-arglists :swank-fuzzy
   :swank-fancy-inspector
   #+(or asdf2 asdf3 sbcl ecl) :swank-asdf
   :swank-package-fu
   :swank-hyperdoc
   #+sbcl :swank-sbcl-exts
   :swank-mrepl :swank-trace-dialog))

