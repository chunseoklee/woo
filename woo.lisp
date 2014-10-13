(in-package :cl-user)
(defpackage woo
  (:nicknames :clack.handler.woo)
  (:use :cl)
  (:import-from :fast-http
                :make-ll-parser
                :make-ll-callbacks
                :make-http-response
                :parser-method
                :parser-http-major
                :parser-http-minor
                :http-parse
                :http-unparse
                :parsing-error)
  (:import-from :fast-http.subseqs
                :byte-vector-subseqs-to-string
                :make-byte-vector-subseq)
  (:import-from :fast-http.byte-vector
                :ascii-octets-to-upper-string
                :byte-to-ascii-upper)
  (:import-from :fast-http.util
                :number-string-p
                :make-collector)
  (:import-from :puri
                :parse-uri-string)
  (:import-from :do-urlencode
                :urldecode)
  (:import-from :cl-async
                :async-io-stream
                :socket-closed
                :write-socket-data
                :socket-data
                :close-socket)
  (:import-from :fast-io
                :make-output-buffer
                :finish-output-buffer
                :with-fast-output
                :fast-write-byte
                :fast-write-sequence)
  (:import-from :chunga
                :make-chunked-stream
                :chunked-stream-output-chunking-p)
  (:import-from :babel
                :string-to-octets)
  (:import-from :flexi-streams
                :make-in-memory-output-stream)
  (:import-from :bordeaux-threads
                :make-thread
                :destroy-thread
                :make-lock
                :acquire-lock
                :release-lock
                :threadp)
  (:import-from :alexandria
                :hash-table-plist
                :copy-stream
                :if-let)
  (:export :run
           :stop))
(in-package :woo)

(defun run (app &key (debug t) (port 5000)
                  (use-thread #+thread-support t
                              #-thread-support nil))
  (let ((server-started-lock (bt:make-lock "server-started")))
    (flet ((start-server ()
             (as:with-event-loop (:catch-app-errors t)
               (as:tcp-server "0.0.0.0" port
                              #'read-cb
                              (lambda (event)
                                (typecase event
                                  (as:tcp-eof ())
                                  (as:tcp-error ()
                                   (log:error (princ-to-string event)))
                                  (as:tcp-info
                                   (log:info (princ-to-string event))
                                   (let ((socket (as:tcp-socket event)))
                                     (write-response-headers socket 500 ())
                                     (as:write-socket-data socket "Internal Server Error"
                                                           :write-cb (lambda (socket)
                                                                       (setf (as:socket-data socket) nil)
                                                                       (as:close-socket socket)))))
                                  (T
                                   (log:info event))))
                              :connect-cb (lambda (socket) (setup-parser socket app debug)))
               (bt:release-lock server-started-lock))))
      (prog1
          (if use-thread
              (bt:make-thread #'start-server)
              (start-server))
        (bt:acquire-lock server-started-lock t)
        (sleep 0.05)))))

(defun read-cb (socket data)
  (let ((parser (getf (as:socket-data socket) :parser)))
    (handler-case (funcall parser data)
      (fast-http:parsing-error (e)
        (log:error "fast-http parsing error: ~A" e)
        (write-response-headers socket 400 ())
        (finish-response socket (princ-to-string e)))
      (fast-http:fast-http-error (e)
        (log:error "fast-http error: ~A" e)
        (write-response-headers socket 500 ())
        (finish-response socket #.(babel:string-to-octets "Internal Server Error"))))))

(defun canonicalize-header-field (data start end)
  (let ((byte (aref data start)))
    (if (or (= byte #.(char-code #\C))
            (= byte #.(char-code #\R))
            (= byte #.(char-code #\S))
            (= byte #.(char-code #\c))
            (= byte #.(char-code #\r))
            (= byte #.(char-code #\s)))
        (let ((field
                (intern (ascii-octets-to-upper-string data :start start :end end)
                        :keyword)))
          (if (find field '(:content-length
                            :content-type
                            :connection
                            :request-method
                            :script-name
                            :path-info
                            :server-name
                            :server-port
                            :server-protocol
                            :request-uri
                            :remote-addr
                            :remote-port
                            :query-string))
              field
              (intern (format nil "HTTP-~:@(~A~)" field) :keyword)))
        ;; This must be a custom header
        (let ((string (make-string (+ 5 (- end start)) :element-type 'character)))
          (loop for i from 0
                for char across "HTTP-"
                do (setf (aref string i) char))
          (do ((i 5 (1+ i))
               (j start (1+ j)))
              ((= j end) (intern string :keyword))
            (setf (aref string i)
                  (code-char (byte-to-ascii-upper (aref data j)))))))))

;; Using Low-level parser of fast-http
(defun setup-parser (socket app debug)
  (let (headers env
        (body-buffer (fast-io::make-output-buffer))

        parsing-host-p

        resource
        method
        version
        host
        (headers-collector (make-collector))
        (header-value-collector nil)
        (current-len 0)

        completedp

        (parser (make-ll-parser :type :request))
        callbacks)
    (flet ((collect-prev-header-value ()
             (when header-value-collector
               (let* ((header-value
                        (byte-vector-subseqs-to-string
                         (funcall header-value-collector)
                         current-len))
                      (header-value
                        (if (number-string-p header-value)
                            (read-from-string header-value)
                            header-value)))
                 (when parsing-host-p
                   (setq host header-value
                         parsing-host-p nil))
                 (funcall headers-collector header-value)))))
      (setq callbacks
            (make-ll-callbacks
             :url (lambda (parser data start end)
                    (declare (ignore parser))
                    ;; TODO: Can be more efficient
                    (setq resource (babel:octets-to-string data :start start :end end)))
             :header-field (lambda (parser data start end)
                             (declare (ignore parser)
                                      (type (simple-array (unsigned-byte 8) (*)) data))
                             (collect-prev-header-value)
                             (setq header-value-collector (make-collector))
                             (setq current-len 0)

                             (let ((field (canonicalize-header-field data start end)))
                               (when (eq field :host)
                                 (setq parsing-host-p t))
                               (funcall headers-collector field)))
             :header-value (lambda (parser data start end)
                             (declare (ignore parser)
                                      (type (simple-array (unsigned-byte 8) (*)) data))
                             (incf current-len (- end start))
                             (funcall header-value-collector
                                      (make-byte-vector-subseq data start end)))
             :headers-complete (lambda (parser)
                                 (collect-prev-header-value)
                                 (setq version
                                       (intern (format nil "HTTP/~A.~A"
                                                       (parser-http-major parser)
                                                       (parser-http-minor parser))
                                               :keyword))
                                 (setq method (parser-method parser))
                                 (setq headers (funcall headers-collector))
                                 (setq env (handle-request method resource version host headers socket))
                                 (setq headers-collector nil
                                       header-value-collector nil))
             :body (lambda (parser data start end)
                     (declare (ignore parser)
                              (type (simple-array (unsigned-byte 8) (*)) data))
                     (do ((i start (1+ i)))
                         ((= i end))
                       (fast-write-byte (aref data i) body-buffer)))
             :message-complete (lambda (parser)
                                 (declare (ignore parser))
                                 (collect-prev-header-value)
                                 (setq completedp t))))
      (setf (getf (as:socket-data socket) :parser)
            (lambda (data)
              (http-parse parser callbacks data)
              (when completedp
                (setq env
                      (nconc (list :raw-body
                                   (flex:make-in-memory-input-stream
                                    (fast-io::finish-output-buffer body-buffer)))
                             env))
                (handle-response socket
                                 (if debug
                                     (funcall app env)
                                     (if-let (res (handler-case (funcall app env)
                                                    (error (error)
                                                      (princ error *error-output*)
                                                      nil)))
                                       res
                                       '(500 nil nil)))
                                 headers
                                 app
                                 debug)))))))

(defun stop (server)
  (if (bt:threadp server)
      (bt:destroy-thread server)
      (as:close-tcp-server server)))


;;
;; Handling requests

(defun parse-host-header (host)
  (let ((pos (position #\: host :from-end t)))
    (unless pos
      (return-from parse-host-header
        (values host nil)))

    (let ((port (subseq host (1+ pos))))
      (if (every #'digit-char-p port)
          (values (subseq host 0 pos)
                  (read-from-string port))
          (values host nil)))))

(defun handle-request (method resource version host headers socket)
  (multiple-value-bind (server-name server-port)
      (if host
          (parse-host-header host)
          (values nil nil))
    (multiple-value-bind (scheme host port path query)
        (puri::parse-uri-string resource)
      (declare (ignore scheme host port))
      (nconc
       (list :request-method method
             :script-name ""
             :server-name server-name
             :server-port (or server-port 80)
             :server-protocol version
             :path-info (do-urlencode:urldecode path :lenientp t)
             :query-string query
             :url-scheme :http
             :request-uri resource
             :clack.streaming t
             :clack.nonblocking t
             :clack.io socket)

       ;; FIXME: Concat duplicate headers with a comma.
       headers))))


;;
;; Handling responses

(defvar *empty-chunk*
  #.(babel:string-to-octets (format nil "0~C~C~C~C"
                                    #\Return #\Newline
                                    #\Return #\Newline)))

(defvar *empty-bytes*
  #.(babel:string-to-octets ""))

(defun write-response-headers (socket status headers)
  (fast-http:http-unparse (make-http-response :status status
                                              :headers headers)
                          (lambda (data)
                            (as:write-socket-data socket data))))

(defun start-chunked-response (socket status headers)
  (write-response-headers socket status (append headers
                                                (list :transfer-encoding "chunked")))

  (let* ((async-stream (make-instance 'as:async-io-stream :socket socket))
         (chunked-stream (chunga:make-chunked-stream async-stream)))
    (setf (chunga:chunked-stream-output-chunking-p chunked-stream) t)
    chunked-stream))

(defun finish-response (socket &optional (body *empty-bytes*))
  (as:write-socket-data socket body
                        :write-cb (lambda (socket)
                                    (setf (as:socket-data socket) nil)
                                    (as:close-socket socket))))

(defun handle-response (socket clack-res request-headers app debug)
  (etypecase clack-res
    (list (handle-normal-response socket clack-res request-headers app debug))
    (function (funcall clack-res (lambda (clack-res)
                                   (handler-case
                                       (handle-normal-response socket clack-res request-headers app debug)
                                     (as:socket-closed ())))))))

(defun handle-normal-response (socket clack-res request-headers app debug)
  (let ((no-body '#:no-body))
    (destructuring-bind (status headers &optional (body no-body))
        clack-res
      (when (eq body no-body)
        (let* ((stream (start-chunked-response socket status headers))
               (connection (getf request-headers :connection))
               (default-close (cond
                                ((string= connection "keep-alive") nil)
                                ((string= connection "close") t))))
          (return-from handle-normal-response
            (lambda (body &key (close nil close-specified-p))
              (etypecase body
                (string (write-sequence (babel:string-to-octets body) stream))
                (vector (write-sequence body stream)))
              (force-output stream)
              (setq close (if close-specified-p
                              close
                              default-close))
              (if close
                  (finish-response socket *empty-chunk*)
                  (setup-parser socket app debug))))))

      (etypecase body
        (null
         (write-response-headers socket status headers)
         (finish-response socket))
        (pathname (let ((stream (start-chunked-response socket status headers)))
                    (with-open-file (in body :direction :input :element-type '(unsigned-byte 8))
                      (copy-stream in stream))
                    (force-output stream)
                    (finish-response socket *empty-chunk*)))
        (list
         (setf body
               (fast-io:with-fast-output (buffer :vector)
                 (loop with content-length = 0
                       for str in body
                       do (let ((bytes (babel:string-to-octets str :encoding :utf-8)))
                            (fast-io:fast-write-sequence bytes buffer)
                            (incf content-length (length bytes)))
                       finally
                          (unless (getf headers :content-length)
                            (setf headers
                                  (append headers
                                          (list :content-length content-length)))))))

         (write-response-headers socket status headers)

         (as:write-socket-data socket body)

         (if (string= (getf request-headers :connection) "close")
             (finish-response socket)
             (setup-parser socket app debug)))
        ((vector (unsigned-byte 8))
         (write-response-headers socket status headers)
         (if (string= (getf request-headers :connection) "close")
             (finish-response socket body)
             (setup-parser socket app debug)))))))
