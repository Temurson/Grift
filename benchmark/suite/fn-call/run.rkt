#lang racket

(require
 racket/date
 math/statistics
 "../../../src/compile.rkt")

#|
Thoughts about improvements 
-- hard code or generate the c-files for a set number of iterations.
|#

;; Controls how many times each benchmark is repeated
(define runs 30)

;; Controls how many time each function call is repeated in
;; order to scale the time to a measurable quantity.
(define schml-iterations 10000)

(define PAGE-SIZE 4096)
;; Number of decimals in formatted latex output
(define decimals 2)

(define this-dir
 (path-only (path->complete-path (find-system-path 'run-file))))

;; This check is a first attempt at providing some protection from
;; this script which can create many files.
(unless (file-exists? (build-path this-dir "run.rkt"))
  (error 'run.rkt "may not work in a repl"))

;; The source directory is where the generated GTLC files will
;; be deposited
(define src-dir (build-path this-dir "src/"))
(unless (directory-exists? src-dir)
  (make-directory src-dir))

;; The temp directory is used to save copies of the C and ASM files
;; that are generated by the Schml Compiler
(define tmp-dir (build-path this-dir "tmp/"))
(unless (directory-exists? tmp-dir)
  (make-directory tmp-dir))

;; This is where the final executable benchmarks are stored
(define exe-dir (build-path this-dir "exe/"))
(unless (directory-exists? exe-dir)
  (make-directory exe-dir))

;; This is where the data is stored for each run of the benchmark
(define logs-dir (build-path this-dir "logs/"))
(unless (directory-exists? logs-dir)
  (make-directory logs-dir))


;; The data files are "Uniquified" by the current hash of the git repo
;; and the date. The hope is that this makes keeping track of the
;; progression of the compiler and the git commit to find that commit
;; easier
(define unique-name
  (let ([date (parameterize ([date-display-format 'iso-8601])
                (date->string (current-date)))]
        [hash (parameterize ([current-output-port (open-output-string)])
                (or (and (system "git rev-parse --short HEAD")
                         (let ((s (get-output-string (current-output-port))))
                           ;; get rid of a trailing newline
                           (substring s 0 (- (string-length s) 1))))
                    "no_hash"))])
    (format "~a-~a-fn-call" date hash)))

(define data-file (build-path logs-dir (string-append unique-name ".dat")))

(define latex-file (build-path this-dir (format "fn-call.tex")))


(define (path dir-path base ext)
  (build-path dir-path (string-append base ext)))

(define (path-string dir-path base ext)
  (path->string (path dir-path base ext)))

;; freshly compile the c tests
(define (c-compile/run/parse base)
  (define (micro->pico x) (* x (expt 10 6)))
  (define spec #px"^time \\(us\\): (\\d+.\\d+)\n$")
  (define src (path-string src-dir base ".c"))
  (define asm (path-string tmp-dir base ".s"))
  (define exe (path-string exe-dir base ".out"))
  (unless (and (system (format "cc ~a -O3 -S -o ~a" src asm))
               (system (format "cc ~a -O3 -o ~a" src exe)))
    (raise (exn (format "compile-c ~a" base) (current-continuation-marks))))
  (for/list ([run (in-range runs)])
    (let* ([result (with-output-to-string (lambda () (system exe)))]
           [parse?  (regexp-match spec result)])
      (unless parse?
        (error 'c-compile/run/parse
               "failed to parse ~a with ~a"
               exe result))
      (let* ([time-us (string->number (cadr parse?))]
             [time-ps (micro->pico time-us)])
        (printf "~a ~a\n" base time-ps)
        time-ps))))

(define c-results
  (for/list ([test '("c-loop"
                     "c-direct" 
                     "c-indirect-stack"
                     "c-indirect-memory")])
    (let-values ([(results) (c-compile/run/parse test)])
      (list test (mean results) (stddev results)))))

(define (schml-compile/run/parse test [rep #f])
  (define (sec->pico x) (* x (expt 10 12)))
  (define spec #px"^time \\(sec\\): (\\d+.\\d+)\n")
  (define base (car test))
  (define code (cdr test))
  (define base^
    (string-downcase
     (if rep
         (string-append base "-" (~a rep))
         base)))
  (define src  (path src-dir base ".schml"))
  (define tmpa (path tmp-dir base^ ".s"))
  (define tmpc (path tmp-dir base^ ".c"))
  (define exe  (path exe-dir base^ ".out"))
  ;; Always regenerate and recompile the files
  (call-with-output-file src #:exists 'replace
    (lambda (p) (pretty-print code p 1)))
  
  (with-output-to-string
    (lambda ()
      (compile src #:cast-rep (or rep 'Twosomes) #:output exe
               #:keep-c tmpc #:keep-a tmpa
               #:cc-opt "-w -O3"
               #:mem (* PAGE-SIZE 3000)
               #:rt (build-path "./runtime.o"))))
  
  (define results
    (for/list ([run (in-range runs)])
      (let* ([result (with-output-to-string
                       (lambda ()
                         (with-input-from-string (format "~a" schml-iterations)
                           (lambda ()
                            (system (format "~a" (path->string exe)))))))]
             [parse?  (regexp-match spec result)])
        (unless parse?
          (error 'schml-compile/run/parse
                 "failed to parse ~a with ~a"
                 exe result))
        (let* ([time-s (string->number (cadr parse?))]
               [time-ps (sec->pico time-s)]
               [time/iter (/ time-ps schml-iterations)])
          (printf "~a ~a ~a\n" base time-ps time/iter)
          time/iter))))
  (values base^ results))

(define schml-loop-test
  `("gtlc-loop" .
    (let ([acc : (GRef Int) (gbox 0)]
          [iters : Int (read-int)])
      (letrec ([run-test
                : (Int -> ())
                (lambda ([i : Int])
                  (gbox-set! acc (+ i (gunbox acc))))])
        (begin
          (timer-start)
          (repeat (i 0 iters) (run-test i))
          (timer-stop)
          (timer-report)
          (gunbox acc))))))

(define schml-tests
  `(("gtlc-static-int-x1" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (f i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))

    ("gtlc-static-int-x2" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (f (f i)) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))

    ("gtlc-static-int-x3" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (f (f (f i))) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))

    ("gtlc-static-int-x4" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (f (f (f (f i)))) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))
    
    ("gtlc-wrapped-int" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([w : (Dyn -> Dyn) f]
             [acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (w i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))
    
    ("gtlc-dynamic-int" .
     (letrec ([f : (Int -> Int) (lambda (n) n)])
       (let ([d : Dyn f]
             [acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (d i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))
    
    ("gtlc-static-dyn" .
     (letrec ([f : (Dyn -> Dyn) (lambda (n) n)])
       (let ([acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (f i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))

    ("gtlc-wrapped-dyn" .
     (letrec ([f : (Dyn -> Dyn) (lambda (n) n)])
       (let ([w : (Int -> Int) f]
             [acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (w i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))
    
    ("gtlc-dynamic-dyn" .
     (letrec ([f : (Dyn -> Dyn) (lambda (n) n)])
       (let ([d : Dyn f]
             [acc : (GRef Int) (gbox 0)]
             [iters : Int (read-int)])
         (letrec ([run-test
                   : (Int -> ())
                   (lambda ([i : Int])
                     (gbox-set! acc (+ (d i) (gunbox acc))))])
           (begin
             (timer-start)
             (repeat (i 0 iters) (run-test i))
             (timer-stop)
             (timer-report)
             (gunbox acc))))))))

(define schml-results
  (cons
   (let-values ([(name results) (schml-compile/run/parse schml-loop-test)])
     (list name (mean results) (stddev results)))
   (for*/list ([test (in-list schml-tests)]
               [rep  '(Twosomes Coercions)])
     (let-values ([(name results) (schml-compile/run/parse test rep)])
       (list name (mean results) (stddev results))))))

(define (check-for x)
  (with-output-to-file "/dev/null" #:exists 'append
    (lambda () (system (format "which ~a" x)))))

(define (gambit-compile exe base)
  (unless (system
           (format
            (string-append
             exe " -o exe/~a.out"
             " -prelude \"(declare (standard-bindings)) (declare (block))\""
             " -cc-options -O3 -exe src/~a.scm")
            base base))
    (error 'gambit-compile)))

(define gambit? #f)
(define gambit-results
  (cond
    [(not gambit?) '()]
    [(check-for "gsc")
     (list (gambit-compile "gsc" "gambit-dynamic"))]
    [(check-for "gambitc")
     (list (gambit-compile "gambitc" "gambit-dynamic"))]
    [else  (display "omitting gambit tests") '()]))


(define (results-map f r*)
  (for/list ([r (in-list r*)])
    (match-let ([(list name mean sdev) r])
      (f name mean sdev))))

(define (result->string name mean sdev)
  (string-append name " " (number->string mean) " " (number->string sdev)))

(define (results->string r*)
  (call-with-output-string
   (lambda (p)
     (for ([s (results-map result->string r*)])
       (display s p) (newline p)))))

(define (decimal->align r d)
    (define s (real->decimal-string r d))
    (unless s (error 'result-latex/decimal-aligned/s))
    (define p? (regexp-match #px"^(\\d+).(\\d+)$" s))
    (unless p? (error 'result-latex/decimal-aligned/p?))
    (define parts (cdr p?))
    (string-append (car parts) " & " (cadr parts)))

(define (results->latex-table r*)
  (call-with-output-string
   (lambda (p)
     (display
      (string-append
       "\\begin{tabular}{| l | r | r |}\n"
       "\\hline\n"
       "Test Name & Time (ps) & Std Dev \\\\ \n"
       #|"\\multicolumn{2}{c|}{  } &"
         "\\multicolumn{2}{c|}{  } \\\\ \n"|#
       "\\hline\n")
      p)
     (for ([r (in-list r*)])
       (match-let ([(list name mean sdev) r])
         (fprintf p "~a & ~a & ~a \\\\ \\hline\n"
                  name 
                  (real->decimal-string mean decimals)
                  (real->decimal-string sdev decimals))))
     (display "\\end{tabular}\n" p))))

(define results (append c-results schml-results gambit-results))

(define results-string (results->string results))

(call-with-output-file data-file #:exists 'replace
  (lambda (p)
    (fprintf p
             (string-append
              "#(test name)"
              " (mean time (ps) per iteration of ~a runs)"
              " (std dev)\n")
             runs)
    (display results-string p)))

(display results-string)

(call-with-output-file latex-file #:exists 'replace
  (lambda (p) (display (results->latex-table results) p)))

(define paper-dir (build-path this-dir ".paper"))
(when (directory-exists? paper-dir)
  (system (format "cp ~a ~a"
                  (path->string latex-file)
                  (path->string (build-path paper-dir "graphics" "fn-call.tex")))))

