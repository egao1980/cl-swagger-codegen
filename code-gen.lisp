(in-package "CL-SWAGGER")

;;; drakma:*header-stream* for DEBUG
(setf drakma:*header-stream* *standard-output*)

;;; set cl-json:*json-identifier-name-to-lisp* AS identical name
;;; ex ==> (setf cl-json:*json-identifier-name-to-lisp* (lambda (x) (string-upcase x)))
(setf cl-json:*json-identifier-name-to-lisp* (lambda (x) x))


(defun fetch-json (this-url)
  "gets JSON with this URL only when response-code is 200"
  (multiple-value-bind (body response-code)
      (http-request this-url :want-stream t)
    (setf (flex:flexi-stream-external-format body) :utf-8)
    (ecase response-code
      (200 (cl-json:decode-json body)))))

;;; RE Pattern 
(defparameter *parameter-pattern* "{([a-zA-Z\-_\.]+)}")

(defun parse-path-parameters (path)
  "returns two values, 1st is non param path element, 2nd are the params.
   ex) /PARAM1/{PARAM2} ==> ((\"PARAM1\") (\"PARAM2\"))"
  (values-list (mapcar #'nreverse
                       (reduce
                        (lambda (acc v)
                          (if (string= "" v)
                              acc
                              (let ((param (cl-ppcre:register-groups-bind (param)
                                               (*parameter-pattern* v) param)))
                                (if param
                                    (list (first acc) (push (param-case param) (second acc)))
                                    (list (push (param-case v) (first acc)) (second acc))))))
                        (cl-ppcre:split "/" (string path))
                        :initial-value (list nil nil)))))

(defun normalize-path-name (name)
  "string --> A-B-C"
  (string-upcase (format nil "~{~A~^-~}" (parse-path-parameters name))))

(defun normalize-path-url (path-url)
  "string --> A/B/C"
  (string-upcase (format nil "~{~A~^/~}" (parse-path-parameters path-url))))

(defun get-in (this-items alist)
  "get lists related to this-items"
  (if (endp this-items) alist
      (get-in (rest this-items)
              (cdr (assoc (car this-items) alist)))))

(defun get-basepath (json)
  "gets base-path"
  (get-in '(:|basePath|) json))

(defun get-schemes (json)
  "gets schemes"
  (first (get-in '(:|schemes|) json)))

(defun get-host (json)
  "gets hostname"
  (get-in '(:|host|) json))

(defun make-urls (json)
  "scheme + hostname + basepath"
  (concatenate 'string (get-schemes json) "://" (get-host json) (get-basepath json)))

(defun get-operation-name (path-name operation-json)
  (param-case
   (or
    (get-in '(:|operationId|) (cdr operation-json))
    path-name)))


(define rest-call-function
  "
(defun rest-call (host url-path
                  &key params content basic-authorization
                    (method :get)
                    (accept \"application/json\")
                    (content-type \"application/json\"))
  \"call http-request with basic params and conteent and authorization\"
  (multiple-value-bind (stream code)
      (drakma:http-request (format nil \"~a~a\" host url-path) :parameters params :content content :basic-authorization basic-authorization :accept accept :content-type content-type :want-stream t :method method)
    (if (equal code 200)
        (progn (setf (flexi-streams:flexi-stream-external-format stream) :utf-8)
               (cl-json:decode-json stream))
        (format t \"HTTP CODE : ~A ~%\" code))))")


(define rest-call-templete-v1
  "
;;
{{#description}}
;; {{{.}}}
{{/description}}
;; * path-url     : {{paths}}
{{#operation-id}}
;; * operation-id : {{operation-id}}
{{/operation-id}}
;;
(defun {{function-name}} (&key params content basic-authorization)
  (rest-call \"{{baseurl}}\" \"{{path-url}}\" 
             :params params 
             :content content
             :basic-authorization basic-authorization
             :method {{method}}
             :accept \"{{accept}}\"
             :content-type \"{{accept-type}}\"))")

(define rest-call-templete-v2
  "
;;
{{#description}}
;; {{{.}}}
{{/description}}
;; * path-url     : {{paths}}
{{#operation-id}}
;; * operation-id : {{operation-id}}
{{/operation-id}}
;;
(defun {{function-name}} ({{#path-args}}{{.}} {{/path-args}}&key params content basic-authorization)
  (rest-call \"{{baseurl}}\" 
             (format nil \"{{path-pattern}}\"{{#path-params}} {{.}}{{/path-params}}) 
             :params params 
             :content content
             :basic-authorization basic-authorization
             :method {{method}}
             :accept \"{{accept}}\"
             :content-type \"{{accept-type}}\"))")


(define convert-json-templete
  "
;;
;; (convert-json #'function \"/path\" content-json)
;;
(defun convert-json (query-fun path body)
  (multiple-value-bind (code stream head)
      (funcall query-fun path body)
    (if (equal code 200) (progn (setf (flexi-streams:flexi-stream-external-format stream) :utf-8)
                                (cl-json:decode-json stream))
        (format t \"failed - code : ~a\" code))))")


(defun rest-call (host url-path
                  &key params content basic-authorization
                    (method :get)
                    (accept "application/json")
                    (content-type "application/json"))
  "call http-request with basic params and conteent and authorization"
  (multiple-value-bind (stream code)
      (drakma:http-request (format nil "~a~a" host url-path) :parameters params :content content :basic-authorization basic-authorization :accept accept :content-type content-type :want-stream t :method method)
    (if (equal code 200)
        (progn (setf (flexi-streams:flexi-stream-external-format stream) :utf-8)
               (cl-json:decode-json stream))
        (format t "HTTP CODE : ~A ~%" code))))


(defun generate-client-with-json (json filepath &optional accept accept-type)
  "generater a lisp code with swagger-json"
  (with-open-file (*standard-output* filepath :direction :output :if-exists :supersede)
    (format t "(ql:quickload \"drakma\")~%(ql:quickload \"cl-json\")~%")
    (rest-call-function)
    (loop for paths in (get-in '(:|paths|) json)
          do (loop for path in (rest paths)
                   do ;;(format t "~%~A==>~A~%" (first paths) (get-in '(:|operationId|) (cdr path)))
                      (when (or (equal (first path) :|get|) (equal (first path) :|post|))
                        (multiple-value-bind (fnames options)
                            (parse-path-parameters (first paths))
                          ;;(format t " ~A ==> ~A ~%" fnames options)
                          (let ((tmp  `((:baseurl . ,(lambda () (make-urls json)))
                                        (:paths . ,(lambda () (car paths)))
                                        (:path-name . ,(lambda () (string-downcase (normalize-path-name (first paths)))))
                                        (:function-name . ,(lambda () (get-operation-name (normalize-path-name (first paths)) path)))
                                        (:path-url . ,(first paths))
                                        (:path-args . ,(remove-duplicates options :test #'string= :from-end t))
                                        (:path-params . ,options)
                                        (:path-pattern . ,(cl-ppcre:regex-replace-all *parameter-pattern* (format nil "~A" (first paths)) "~a"))
                                        (:first-name . ,(lambda () (string-downcase (format nil "~A" (first path)))))
                                        (:method . ,(lambda() (format nil ":~A" (first path))))
                                        (:operation-id . ,(get-in '(:|operationId|) (cdr path)))
                                        (:description . ,(cl-ppcre:split "\\n" (or (get-in '(:|description|) (cdr path)) "")))
                                        (:accept . ,"application/json")
                                        (:accept-type . ,"application/json"))))
                            (if options
                                (rest-call-templete-v2 tmp)
                                (rest-call-templete-v1 tmp)))))))
    (convert-json-templete)))


(defun generate-client (url filepath &optional accept accept-type)
  "exposing function for client code generater"
  (if (typep url 'pathname) (generate-client-with-json (cl-json:decode-json-from-source url) filepath accept accept-type)
      (generate-client-with-json (fetch-json url) filepath accept accept-type)))

;;(with-output-to-string (st) (run-program "curl" '("-ks" "-u" "mapr:mapr" "https://172.16.28.138:8443/rest/alarm/list") :output st))
