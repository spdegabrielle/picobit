#lang racket

(require (only-in unstable/port read-all)
         racket/runtime-path)
(require "utilities.rkt"
         "ast.rkt"
         "env.rkt"
         "parser.rkt"
         "context.rkt"
         "comp.rkt"
         "asm.rkt"
         "encoding.rkt"
         "analysis.rkt"
         "scheduling.rkt"
         "tree-shaker.rkt")

;-----------------------------------------------------------------------------

(define (expand-includes exprs)
  (map (lambda (e)
         (if (eq? (car e) 'include)
             (cons 'begin
                   (expand-includes
                    (with-input-from-file (cadr e) read-all)))
             e))
       exprs))

(define-runtime-path compiler-dir ".")

(define (parse-file filename)
  (let* ((library
          (with-input-from-file (build-path compiler-dir "library.scm")
            read-all))
         (toplevel-exprs
          (expand-includes
           (append library
                   (with-input-from-file filename read-all))))
         (global-env
          (make-global-env))
         (parsed-prog
          (parse-top (cons 'begin toplevel-exprs) global-env)))

    (for-each
     (lambda (node)
       (mark-needed-global-vars! global-env node))
     parsed-prog)

    (extract-parts
     parsed-prog
     (lambda (defs after-defs)

       (define (make-seq-preparsed exprs)
         (let ((r (make-seq #f exprs)))
           (for-each (lambda (x) (set-node-parent! x r)) exprs)
           r))

       (define (make-call-preparsed exprs)
         (let ((r (make-call #f exprs)))
           (for-each (lambda (x) (set-node-parent! x r)) exprs)
           r))

       (if (var-needed?
            (env-lookup global-env '#%readyq))
           (make-seq-preparsed
            (list (make-seq-preparsed defs)
                  (make-call-preparsed
                   (list (parse 'value '#%start-first-process global-env)
                         (let* ((pattern
                                 '())
                                (ids
                                 (extract-ids pattern))
                                (r
                                 (make-prc #f
                                           '()
                                           #f
                                           (has-rest-param? pattern)
                                           #f))
                                (new-env
                                 (env-extend global-env ids r))
                                (body
                                 (make-seq-preparsed after-defs)))
                           (set-prc-params!
                            r
                            (map (lambda (id) (env-lookup new-env id))
                                 ids))
                           (set-node-children! r (list body))
                           (set-node-parent! body r)
                           r)))
                  (parse 'value
                         '(#%exit)
                         global-env)))
           (make-seq-preparsed
            (append defs
                    after-defs
                    (list (parse 'value
                                 '(#%halt)
                                 global-env)))))))))

(define (extract-parts lst cont)
  (if (or (null? lst)
          (not (def? (car lst))))
      (cont '() lst)
      (extract-parts
       (cdr lst)
       (lambda (d ad)
         (cont (cons (car lst) d) ad)))))

;------------------------------------------------------------------------------

(define (optimize-code code)
  (let ((bbs (code->vector code)))
    (resolve-toplevel-labels! bbs)
    (tree-shake! bbs)))

(define (compile filename)
  (let* ((node (parse-file filename))
         (hex-filename
          (path-replace-suffix filename ".hex")))
    
    (adjust-unmutable-references! node)

    (let ((ctx (comp-none node (make-init-context))))
      (let ((prog (linearize (optimize-code (context-code ctx)))))
        ;; r5rs's with-output-to-file (in asm.rkt) can't overwrite. bleh
        (when (file-exists? hex-filename)
          (delete-file hex-filename))
        (assemble prog hex-filename)))))


(void (compile (vector-ref (current-command-line-arguments) 0)))