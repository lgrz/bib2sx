(module 
  bibtex
  racket
  
  (provide (all-defined-out))
  
  (require parser-tools/lex)
  (require (prefix-in : parser-tools/lex-sre))
  (require parser-tools/yacc)
  
  (require xml)
  (require xml/xexpr)
  
  ;; Lexical analysis of BibTeX
  
  ; Most of the complexity in analyzing BibTeX has bene
  ; pushed into the lexer.  The lexer may recognize the same
  ; token different depending on the context.
  
  ; The lexer tracks whether it is inside quotes (") and
  ; how many layers of {}-nesting it is within.
  
  ; At two layers of {}-nesting, most tokens are treated as
  ; strings and whitespace becomes a string as well.
  
  ; At one layer of {}-nesting and between quotes ("),
  ; most tokens are strings and whitespace becomes a string
  ; as well.
  
  
  ; Token types:
  (define-empty-tokens PUNCT (@ |{| |}| |"| |#| |,| =))
  (define-empty-tokens EOF (EOF))
  
  (define-tokens EXPR (ID STRING SPACE))
  
  
  
  (define-lex-abbrev bibtex-id 
    (:+ (char-complement (char-set " \t\r\n{}@#=,\\\""))))
  
  (define-lex-abbrev bibtex-comment
    (:: (or #\c #\C) (or #\o #\O) (or #\m #\M) (or #\m #\M) (or #\e #\E) (or #\n #\N) (or #\t #\T)))
  
  (define-lex-abbrev bibtex-preamble
    (:: (or #\p #\P) (or #\r #\R) (or #\e #\E) (or #\a #\A) (or #\m #\M) (or #\b #\B) (or #\l #\L) (or #\e #\E)))
  
  
  (define (bibtex-lexer port [nesting 0] [in-quotes? #f])
    
    ; helpers to recursively call the lexer with defaults:
    (define (lex port) 
      (bibtex-lexer port nesting in-quotes?))
    
    (define (lex+1 port) 
      ; increase {}-nesting
      (bibtex-lexer port (+ nesting 1) in-quotes?))
    
    (define (lex-1 port) 
      ; increase {}-nesting
      (bibtex-lexer port (- nesting 1) in-quotes?))
    
    (define (lex-quotes port)
      ; toggle inside quotes
      (bibtex-lexer port nesting (not in-quotes?)))
    
    (define (not-quotable?) 
      ; iff not inside a string context
      (and (not in-quotes?) (< nesting 2)))
    
    {(lexer
      [(eof)
       empty-stream]
      
      [(:+ whitespace)
       (if (not-quotable?)
           (lex input-port)
           (stream-cons (token-SPACE lexeme)
                        (lex input-port)))]
      
      ["#"
       (stream-cons (if (not-quotable?) 
                        (token-#) (token-STRING lexeme))
                    (lex input-port))]
      
      ["@"
       (stream-cons (if (not-quotable?) 
                        (token-@) (token-STRING lexeme))
                    (lex input-port))]
      
      ["="
       (stream-cons (if (not-quotable?) 
                        (token-=) (token-STRING lexeme))
                    (lex input-port))]
      
      [","
       (stream-cons (if (not-quotable?) 
                        (|token-,|) (token-STRING lexeme))
                    (lex input-port))]
      
      [#\"
       (cond
         [in-quotes?        
          ;=>
          ; pretend we're closing a {}-string
          (stream-cons (|token-}|)
                       (lex-quotes input-port))]
         
         [(and (not in-quotes?) (= nesting 1))
          ;=>
          ; pretend we're opening a {}-string
          (stream-cons (|token-{|)
                       (lex-quotes input-port))]
         
         [(and (not in-quotes?) (>= nesting 2))
          ;=>
          (stream-cons (token-STRING lexeme)
                       (lex input-port))])]
      
      ["\\"
       (stream-cons (token-STRING "\\")
                    (lex input-port))]
      
      ["\\{"
       (stream-cons (token-STRING "{")
                    (lex input-port))]
      
      ["\\}"
       (stream-cons (token-STRING "}")
                    (lex input-port))]
      
      [(:: "{" (:* whitespace))
       (begin
         (stream-cons (|token-{|)
                      (if (and (<= nesting 1) (not in-quotes?))
                          (lex+1 input-port)
                          (if (= (string-length lexeme) 1)
                              (lex+1 input-port)
                              (stream-cons (token-SPACE (substring lexeme 1))
                                           (lex+1 input-port))))))]
      
      [(:: (:* whitespace) "}")
       (begin
         (stream-cons (|token-}|)
                      (if (and (<= nesting 2) (not in-quotes?))
                          (lex-1 input-port)
                          (if (= (string-length lexeme) 1)
                              (lex-1 input-port)
                              (stream-cons (token-SPACE (substring 
                                                         lexeme 0 
                                                         (- (string-length lexeme) 1)))
                                           (lex-1 input-port))))))]
      
      [(:+ numeric)
       (stream-cons (token-STRING lexeme)
                    (lex input-port))]
      
      [bibtex-id
       (stream-cons (if (not-quotable?)
                        (token-ID (string->symbol lexeme)) 
                        (token-STRING lexeme))
                    (lex input-port))])
     
     port})
  
  
  ; generator-token-generator : port -> (-> token)
  (define (generate-token-generator port)
    (define tokens (bibtex-lexer port))
    (λ ()
      (if (stream-empty? tokens)
          (token-EOF)
          (let
              ([tok (stream-first tokens)])
            (set! tokens (stream-rest tokens))
            tok))))
  
  
  
  ;; Parsing BibTeX
  
  ; flatten-top-level-quotes : expr* -> expr*
  (define (flatten-top-level-quotes exprs)
    ; removes the top level {}-quotes because these
    ; should not influence formatting.
    (match exprs
      ['()
       '()]
      
      [(cons `(quote ,values) rest)
       (append values (flatten-top-level-quotes rest))]
      
      [(cons hd tl)
       (cons hd (flatten-top-level-quotes tl))]))
  
  ; simplify-quotes : expr* -> expr*
  (define (simplify-quotes exprs)
    ; concatenates and simplifies where possible
    (match exprs
      ['()
       '()]
      
      [`(',substring . ,tl)
       (define reduced (simplify-quotes substring))
       (when (and (list? reduced) (= (length reduced) 1))
         (set! reduced (car reduced)))
       (cons `(quote ,reduced)
             (simplify-quotes tl))]
      
      [`(,(and a (? string?)) ,(and b (? string?)) . ,rest)
       (simplify-quotes (cons (string-append a b) rest))]
      
      [(cons hd tl)
       (cons hd (simplify-quotes tl))]))
  
  ; flatten+simplify : expr* -> expr*
  (define (flatten+simplify exprs)
    (simplify-quotes (flatten-top-level-quotes exprs)))
  
  ; helpers:
  (define (symbol-downcase s)
    (string->symbol (string-downcase (symbol->string s))))
  
  ; bibtex-parse : (-> token) -> bibtex-ast
  (define bibtex-parse
    (parser
     [grammar 
      (itemlist [{item itemlist}  (cons $1 $2)]
                [{}               '()]
                
                [{ID   itemlist}  $2]
                [{|,|  itemlist}  $2])
      
      (item [{|@| ID |{| taglist |}|} 
             ; =>
             (cons (symbol-downcase $2) $4)])
      
      (tag [{ID}           $1]
           [{ID = expr}    (cons (symbol-downcase $1)
                                 (flatten+simplify $3))])
      
      (expr [{atom |#| expr}       (cons $1 $3)]
            [{atom}                (list $1)])
      
      (atom  [{ID}                  (symbol-downcase $1)]
             [{STRING}              $1]
             [{SPACE}               $1]
             [{ |{| atomlist |}| }  (list 'quote $2)])
      
      (atomlist [{atom atomlist}    (cons $1 $2)]
                [{}                 '()])
      
      (taglist [{tag |,| taglist}   (cons $1 $3)]
               [{tag}               (list $1)]
               [{}                 '()])]
     
     
     [tokens PUNCT EOF EXPR]
     
     [start itemlist]
     
     [end EOF]
     
     [error (lambda (tok-ok? tok-name tok-value)
              (error (format "parsing error: ~a ~a ~a"
                             tok-ok? tok-name tok-value)))]))
  
  
  ;; BibTeX formatting
  
  (define bibtex-default-strings
    #hasheq((jan . ("January"))
            (feb . ("February"))
            (mar . ("March"))
            (apr . ("April"))
            (may . ("May"))
            (jun . ("June"))
            (jul . ("July"))
            (aug . ("August"))
            (sep . ("September"))
            (oct . ("October"))
            (nov . ("November"))
            (dec . ("December"))))
  
  
  ;; Inlining @string values into entries
  
  ; bibtex-inline-strings : bibtex-ast -> bibtex-ast
  (define (bibtex-inline-strings
           items 
           [env bibtex-default-strings])
    
    (define ((replace env) expr)
      (if (symbol? expr)
          (hash-ref env expr (λ () (list "")))
          (list expr)))
    
    (define (inline exprs [env env])
      (apply append (map (replace env) exprs)))
    
    (define (extend* env names exprs)
      (for/fold 
       ([env env])
       ([n names]
        [e exprs])
        (hash-set env n (inline e env))))
    
    (match items
      
      ['()
       '()]
      
      ; TODO: Add handling for @preamble and @comment
      
      ; Pick up more bindings:
      [(cons `(string (,names . ,exprs) ...) rest)
       ;=>
       (bibtex-inline-strings rest (extend* env names exprs))]
      
      [(cons `(,item-type ,key (,names . ,exprs) ...) rest)
       ;=>
       (cons `(,item-type ,key ,@(map cons names (map inline exprs)))
             (bibtex-inline-strings rest env))]
      
      ))
  
  
  ;; Compiling back to .bib
  
  (define (bibtex-exprs->bibstring exprs)
    
    (define (escape str)
      (set! str (string-replace str "{" "\\{"))
      (set! str (string-replace str "}" "\\}"))
      str)
    
    (match exprs
      
      [(? string?)
       exprs]
      
      [(list (and sym (? symbol?)))
       (symbol->string sym)]
      
      [else
       ;=>
       
       (define (expr->string-list expr)
         (match expr
           [(? string?)         (list (escape expr))]
           [(? symbol?)         (list "} # " (symbol->string expr) " # {")]
           
           [`(quote (quote . ,s))
            `("{" ,@(expr->string-list `(quote . ,s)) "}")]
           
           [`(quote ,(and s (? string?)))
            ; =>
            (list "{" s "}")]
           
           [`(quote (,s ...))
            ; =>
            `("{" ,@(apply append (map expr->string-list s)) "}")]))
       
       (string-append (apply string-append (apply append (map expr->string-list exprs))))]))
  
  
  
  (define (bibtex-item->bibstring item)
    (match item
      [`(,item-type ,key (,names . ,exprs) ...)
       (string-append
        "@" (symbol->string item-type) "{" (symbol->string key) ",\n"
        (apply string-append (for/list ([n names]
                                        [e exprs])
                               (format "  ~a = { ~a },\n" n (bibtex-exprs->bibstring e))))
        "}\n")]))
  
  
  ;; Flattening:
  
  (define (bibtex-flatten-strings items)
    
    (define (flatten-item item)
      (match item
        [`(,item-type ,key (,names . ,exprs) ...)
         `(,item-type ,key
                      ,@(for/list ([n names]
                                   [e exprs])
                          (cons n (bibtex-exprs->bibstring e))))]))
    
    (map flatten-item items))
  
  
  
  ;; Converting to XML:
  
  (define (bibtex-ast->xml items)
    
    (define (exprs->xexpr exprs)
      (if (string? exprs)
          `(([value ,exprs]))
          (for/list ([e exprs])
            (match e
              [(? symbol?)
               (symbol->string e)]
              
              [(? string?)             e]
              
              [`(quote ,(? string?))   e]
              
              [`(quote (quote . ,body))
               `(quote ,@(exprs->xexpr 
                          (list `(quote . ,body))))]
              
              [`(quote (,exprs ...))
               `(quote ,@(exprs->xexpr exprs))]))))
    
    (define (item->xexpr item)
      (match item
        [`(,item-type ,key (,names . ,exprs) ...)
         `(,item-type (bibtex-key ,(symbol->string key))
                      ,@(for/list ([n names]
                                   [e exprs])
                          `(,n ,@(exprs->xexpr e))))]))
    
    (xexpr->xml `(bibtex ,@(map item->xexpr items))))
  
  
  
  
  
  
  ;; Converting to JSON:
  
  (define (bibtex-ast->json items)
    (string-join (map bibtex-item->json items) ",\n"
                 #:before-first "[\n"
                 #:after-last "\n]\n"))
  
  (define (bibtex-item->json item)
    
    (define (escape str)
      (when (symbol? str)
        (set! str (symbol->string str)))
      (set! str (string-replace str "\\" "\\\\"))
      (set! str (string-replace str "\r" "\\r"))
      (set! str (string-replace str "\n" "\\n"))
      (set! str (string-replace str "\t" "\\t"))
      (set! str (string-replace str "\"" "\\\""))
      (set! str (string-replace str "\'" "\\\'"))
      (string-append "\"" str "\""))
    
    (define (expr->json expr)
      (match expr
        [(? symbol?)
         (escape (car (hash-ref bibtex-default-strings expr (λ () (list "")))))]
        
        [`(quote (,exprs ...))
         (string-append "[" (string-join (map expr->json exprs) ", ") "]")]
        
        [`(quote ,expr)
         (string-append "[" (expr->json expr) "]")]
        
        [(? string?)
         (escape expr)]
        
        [else 
         (error (format "no rule for expr->json: ~a" expr))]))
    
    (match item
      [`(,item-type ,key (,names . ,exprs) ...)
       
       
       (define entries
         (for/list ([n names] [e exprs])
           (format "~a: ~a" 
                   (escape n) 
                   (if (string? e)
                       (escape e)
                       (string-append "[" (string-join (map expr->json e) ",") "]")))))
       
       (string-append
        "{" 
        (string-join entries ",\n " #:before-first " " #:after-last ",\n ")
        "\"bibtexKey\": " (escape key)
        " }")]))
  
  
  )