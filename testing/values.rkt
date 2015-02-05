#lang typed/racket

(require ;;racket/port
         schml/src/helpers)

(provide (all-defined-out))

(define-type Test-Value (U blame bool int dyn gbox function))

(struct not-lbl ([value : String])
	#:transparent)
(struct blame ([static? : Boolean]
	       [lbl : (U not-lbl String False)])
	#:transparent)
(struct bool ([value : Boolean])
	#:transparent)
(struct int ([value : Integer])
	#:transparent)
(struct dyn ()
	#:transparent)
(struct function ()
	#:transparent)

(struct gbox ([value : Test-Value])
  #:transparent)


(: value=? (Any Any . -> . Boolean))
(define (value=? x y)
  (or (and (blame? x) (blame? y) (blame=? x y))
      (and (bool? x) (bool? y) (bool=? x y))
      (and (int? x) (int? y) (int=? x y))
      (and (gbox? x) (gbox? y) (value=? x y))
      (and (dyn? x) (dyn? y))
      (and (function? x) (function? y))))

(: blame=? (blame blame . -> . Boolean))
(define (blame=? x y)
  (and 
   (eq? (blame-static? x) (blame-static? y))
   (let ([x (blame-lbl x)]
	 [y (blame-lbl y)])
     (cond
      [(not-lbl? x) (not (equal? (not-lbl-value x) y))]
      [(not-lbl? y) (not (equal? (not-lbl-value y) x))]
      [(or (not x) (not y)) #t]
      [else
       (and (string? x) (string? y)
            (cond
             [(equal? x y)]
             [(regexp-match y x) #t]
             [else #f]))]))))
      

(: bool=? (bool bool . -> . Boolean))
(define (bool=? x y)
  (eq? (bool-value x) (bool-value y)))

(: int=? (int int . -> . Boolean))
(define (int=? x y)
  (equal? (int-value x) (int-value y)))

#| capture the output of exp on current-output-port and match
   as if it were returning a value from one of our compiled
   programs.
|#
(define-syntax-rule (observe exp)
  (let ([s (with-output-to-string (lambda () exp))])
    (when (trace? 'Out 'All 'Vomit) (logf "program output:\n ~a\n" s))
    (cond
     [(regexp-match #rx".*Int : ([0-9]+)" s) => 
      (lambda (r)
        (int (cast (string->number (cadr (cast r (Listof String)))) Integer)))]
     [(regexp-match #rx".*Bool : #(t|f)" s) =>
      (lambda (r)
        (bool (not (equal? "f" (cadr (cast r (Listof String)))))))]
     [(regexp-match #rx".*Function : \\?" s) (function)]
     [(regexp-match #rx".*Dynamic : \\?" s) (dyn)]
     [else (blame #f s)])))