(in-package #:jclass)

(defmacro def-serialization (name
			     lambda-list
			     deserialization-input
			     serialization-body
			     deserialization-body)
  (with-gensyms (argument)
    `(progn
       (setf (gethash ',name *serializers*)
	     (lambda (,argument)
	       (destructuring-bind ,lambda-list ,argument
		 ,serialization-body)))
       (setf (gethash ',name *deserializers*)
	     (lambda (&rest ,argument)
	       (destructuring-bind (,lambda-list ,deserialization-input)
		   ,argument
		 ,deserialization-body))))))

(eval-when (:compile-toplevel :load-toplevel :execute)

  (defparameter *serializers*
    (make-hash-table :test 'eq))

  (defparameter *deserializers*
    (make-hash-table :test 'eq))

  (defun expand-serializer (form)
    (if (symbolp form)
	form
	(let ((serial-fn (gethash (car form) *serializers*)))
	  (if serial-fn
	      (funcall serial-fn (cdr form))
	      (error "Can't find serializer for ~A" form)))))

  (defun expand-deserializer (form &rest args)
    (if (symbolp form)
	(destructuring-bind (value) args
	  `(setf ,form ,value))
	(let ((deserial-fn (gethash (car form) *deserializers*)))
	  (if deserial-fn
	      (apply deserial-fn (cdr form) args)
	      (error "Can't find deserializer for ~A: ~A" form args)))))

  (def-serialization with-length (unit list fields &rest body) stream
    (with-gensyms (term)
      `(list
	(,unit (length ,list))
	(mapcar (lambda (&rest ,term)
		  (destructuring-bind (,fields) ,term
		    (list ,@(mapcar #'expand-serializer body))))
		,list)))
    (with-gensyms (item-count)
      `(let ((,item-count ,(list (ccase unit
				   (u1 'parse-u1)
				   (u2 'parse-u2)
				   (u4 'parse-u4))
				 stream)))
	 (setf ,list
	       (loop repeat ,item-count collect
		     (let ,(if (symbolp fields) `(,fields) fields)
		       ,@(loop for form in body
			       collect (expand-deserializer form stream))
		       ,(if (symbolp fields) fields `(list ,@fields))))))))

  ;; Byte manipulation

  (def-serialization u1 (value) byte-stream
    `(u1 ,(expand-serializer value))
    (expand-deserializer value `(parse-u1 ,byte-stream)))
  
  (def-serialization u2 (value) byte-stream
    `(u2 ,(expand-serializer value))
    (expand-deserializer value `(parse-u2 ,byte-stream)))

  (def-serialization u4 (value) byte-stream
    `(u4 ,(expand-serializer value))
    (expand-deserializer value `(parse-u4 ,byte-stream)))

  ;; Constant pool references

  (def-serialization utf8-info (text) utf8-index
    `(pool-index (make-utf8-info ,text))
    `(setf ,text (utf8-info-text (aref (pool-array) ,utf8-index))))

  (def-serialization class-info (name) class-index
    `(pool-index (make-class-info ,name))
    `(setf ,name (class-info-name (aref (pool-array) ,class-index))))

  (def-serialization name-and-type-info (name type) nti-index
    `(pool-index (make-name-and-type-info ,name ,type))
    (with-gensyms (info-ref)
      `(let ((,info-ref (aref (pool-array) ,nti-index)))
	 (setf ,name (name-and-type-info-name ,info-ref))
	 (setf ,type (name-and-type-info-type ,info-ref)))))

  (def-serialization method-handle-info (kind reference) mhi-index
    `(pool-index (make-method-handle-info ,kind ,reference))
    (with-gensyms (handle-ref)
      `(let ((,handle-ref (aref (pool-array) ,mhi-index)))
	 (setf ,kind      (method-handle-info-kind      ,handle-ref))
	 (setf ,reference (method-handle-info-reference ,handle-ref)))))

  (def-serialization module-info (name) module-index
    `(pool-index (make-module-info ,name))
    `(setf ,name (make-module-info (aref (pool-array) ,module-index))))

  (def-serialization package-info (name) package-index
    `(pool-index (make-package-info ,name))
    `(setf ,name (make-package-info (aref (pool-array) ,package-index))))
  
  ;; Special (de)serialization functions

  (def-serialization access-modifiers (flags modifier-list) bytes
    `(access-modifiers ,flags ,modifier-list)
    `(setf ,flags (access-flag-lookup ,bytes ,modifier-list)))

  (def-serialization raw-bytes (raw-bytes) byte-stream
    `(coerce 'list ,raw-bytes)
    ;; byte-stream is a class-bytes struct
    (with-gensyms (byte-list)
      `(setf ,raw-bytes
	     (let ((,byte-list ,byte-stream))
	       (with-slots (array index) ,byte-list
		 (parse-bytes (- (length array) index)
			      ,byte-list))))))

  ;; Pool index with unspecified type

  (def-serialization pool-index (constant) index
    `(pool-index ,constant)
    `(setf ,constant (aref (pool-array) ,index)))

  ;; Structures

  (def-serialization field (field) byte-stream
    `(byte-list ,field (constant-pool))
    `(setf ,field (parse-field-info ,byte-stream (pool-array))))
  
  (def-serialization method (method) byte-stream
    `(byte-list ,method (constant-pool))
    `(setf ,method (parse-method-info ,byte-stream (pool-array))))

  (def-serialization attribute (attribute) byte-stream
    `(byte-list ,attribute (constant-pool))
    `(setf ,attribute (parse-field-info ,byte-stream (pool-array))))

  ) ; end eval-when

(defgeneric byte-list (pool struct)
  (:documentation "Constructs the binary form of a JVM structure."))

(defmacro def-jstruct (name slots &body body)
  (with-gensyms (struct-obj pool byte-stream)
    `(progn
       (defstruct (,name (:constructor ,(symbol-concatenate 'make- name) ,slots))
	 ,@slots)

       (defmethod byte-list (,pool (,struct-obj ,name))
	 (flet ((constant-pool () ,pool)
		(pool-index (constant) (pool-index ,pool constant)))
	   (declare (ignorable (function constant-pool)
			       (function pool-index)))
	   (with-slots ,slots ,struct-obj
	     (list ,@(mapcar #'expand-serializer body)))))

       (defun ,(symbol-concatenate 'parse- name) (,byte-stream ,pool)
	 (flet ((pool-array () ,pool))
	   (declare (ignorable (function pool-array)))
	   (let ,slots
	     ,@(loop for form in body
		     collect (expand-deserializer form byte-stream))
	     (,(symbol-concatenate 'make- name) ,@slots)))))))

(defmacro def-attribute (name name-string slots &body body)
  (with-gensyms (struct-obj pool byte-stream)
    `(progn
       (defstruct (,name (:constructor ,(symbol-concatenate 'make- name) ,slots))
	 ,@slots)

       (defmethod byte-list (,pool (,struct-obj ,name))
	 (flet ((constant-pool () ,pool)
		(pool-index (constant) (pool-index ,pool constant)))
	   (declare (ignorable (function constant-pool)
			       (function pool-index)))
	   (flet ((serialize-body ()
		    (with-slots ,slots ,struct-obj
		      (list ,@(mapcar #'expand-serializer body)))))
	     (let ((body (flatten (serialize-body) :remove-nil t)))
	       (list
		(u2 (pool-index (make-utf8-info ,name-string)))
		(u4 (length body))
		body)))))

       (setf (gethash ,name-string *attribute-parsers*)
	     (lambda (,byte-stream ,pool)
	       (declare (ignorable ,byte-stream))
	       (flet ((pool-array () ,pool))
		 (declare (ignorable (function pool-array)))
		 (let ,slots
		   ,@(loop for form in body
			   collect (expand-deserializer form byte-stream))
		   (,(symbol-concatenate 'make- name) ,@slots))))))))

(defparameter *attribute-parsers*
  (make-hash-table :test 'equal))

(defun parse-attribute (bytes pool-array &rest arguments)
  (let* ((name-index (parse-u2 bytes))
	 (name       (aref pool-array name-index))
	 (length     (parse-u4 bytes))
	 (body       (parse-bytes length bytes)))
    (assert (utf8-info-p name) (name-index)
	    'class-format-error
	    :message "Attribute name is not a UTF-8 constant")
    (restart-case
	(apply (gethash (utf8-info-text name) *attribute-parsers*
			(lambda (bytes pool-array)
			  (declare (ignore bytes pool-array))
			  (error 'class-format-error
				 :message (format nil "Unknown attribute ~A"
						  (utf8-info-text name)))))
	       (make-class-bytes :array body :index 0)
	       pool-array
	       arguments)
      (ignore-attribute ()
	:report "Use the raw attribute byte array"
	(list (utf8-info-text name) body)))))

(defparameter *field-modifiers*
  '((:public       #x0001)
    (:private      #x0002)
    (:protected    #x0004)
    (:static       #x0008)
    (:final        #x0010)
    (:volatile     #x0040)
    (:transient    #x0080)
    (:synthetic    #x1000)
    (:enum         #x4000)))

(def-jstruct field-info (flags name descriptor attributes)
  (u2 (access-modifiers flags *field-modifiers*))
  (u2 (utf8-info name))
  (u2 (utf8-info descriptor))
  (with-length u2 attributes attribute
    (attribute attribute)))

(defparameter *method-modifiers*
  '((:public       #x0001)
    (:private      #x0002)
    (:protected    #x0004)
    (:static       #x0008)
    (:final        #x0010)
    (:synchronized #x0020)
    (:bridge       #x0040)
    (:varargs      #x0080)
    (:native       #x0100)
    (:abstract     #x0400)
    (:strict       #x0800)
    (:synthetic    #x1000)))

(def-jstruct method-info (flags name descriptor attributes)
  (u2 (access-modifiers flags *method-modifiers*))
  (u2 (utf8-info name))
  (u2 (utf8-info descriptor))
  (with-length u2 attributes attribute
    (attribute attribute)))

(defparameter *class-modifiers*
  '((:public       #x0001)
    (:final        #x0010)
    (:super        #x0020)
    (:interface    #x0200)
    (:abstract     #x0400)
    (:synthetic    #x1000)
    (:annotation   #x2000)
    (:enum         #x4000)
    (:module       #x8000)))

(def-jstruct java-class
    (minor-version major-version flags name parent interfaces fields methods attributes)
  ;; handle version number independently for easy constant pool manipulation
  (u2 (access-modifiers flags *class-modifiers*))
  (u2 (class-info name))
  (u2 (class-info parent))
  (with-length u2 interfaces interface
    (u2 (class-info interface)))
  (with-length u2 fields field
    (field field))
  (with-length u2 methods method
    (method method))
  (with-length u2 attributes attribute
    (attribute attribute)))

(defun java-class-bytes (java-class &optional (pool (make-constant-pool)))
  ;; resolve the constants first
  (let ((bytes (byte-list pool java-class)))
    (flatten (list*
	      (u4 #xCAFEBABE) ; file magic number
	      (u2 (java-class-minor-version java-class))
	      (u2 (java-class-major-version java-class))
	      (constant-pool-bytes pool)
	      bytes)
	     :remove-nil t)))

(defun disassemble-jclass (bytes)
  (let* ((cbytes (make-class-bytes :array bytes :index 0))
	 (magic  (when (/= (parse-u4 cbytes) #xCAFEBABE)
		   (error 'class-format-error
			  :message
			  "Not a Java class file: missing magic number 0xCAFEBABE")))
	 (minor-version (parse-u2 cbytes))
	 (major-version (parse-u2 cbytes))
	 (pool-array    (parse-constant-pool cbytes))
	 (jclass        (parse-java-class cbytes pool-array)))
    (declare (ignore magic))
    (setf (java-class-minor-version jclass) minor-version)
    (setf (java-class-major-version jclass) major-version)
    (values jclass pool-array)))

(defun disassemble-file (path)
  (with-open-file (stream path
			  :direction :input
			  :element-type '(unsigned-byte 8)
			  :if-does-not-exist :error)
    (let* ((length (file-length stream))
	   (buffer (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence buffer stream)
      (disassemble-jclass buffer))))

(def-attribute constant-value "ConstantValue" (value)
  (u2 (utf8-info value)))

;; Code

;; StackMapTable

(def-attribute exceptions "Exceptions" (exceptions)
  (with-length u2 exceptions (ex)
    (u2 (class-info ex))))

(defparameter *inner-class-modifiers*
  '((:public       #x0001)
    (:private      #x0002)
    (:protected    #x0004)
    (:static       #x0008)
    (:final        #x0010)
    (:interface    #x0200)
    (:abstract     #x0400)
    (:synthetic    #x1000)
    (:annotation   #x2000)
    (:enum         #x4000)))

(def-attribute inner-classes "InnerClasses" (classes)
  (with-length u2 classes (inner outer name access)
    (u2 (class-info inner))
    (u2 (class-info outer))
    (u2 (utf8-info name))
    (u2 (access-modifiers *inner-class-modifiers* access))))

(def-attribute enclosing-method "EnclosingMethod" (class name type)
  (u2 (class-info class))
  (u2 (name-and-type-info name type)))

(def-attribute synthetic "Synthetic" ())

(def-attribute signature "Signature" (signature)
  (u2 (utf8-info signature)))

(def-attribute source-file "SourceFile" (name)
  (u2 (utf8-info name)))

(def-attribute source-debug-extension "SourceDebugExtension" (debug)
  (raw-bytes debug))

;; LineNumberTable

;; LocalVariableTable

;; LocalVariableTypeTable

(def-attribute deprecated "Deprecated" ())

(defun write-element-value (tag value pool)
  (list
   (u1 (char-code tag))
   (ccase tag
     ((#\B #\I #\S #\Z)
      (u2 (pool-index pool (make-integer-info value))))
     (#\C (u2 (pool-index pool (make-integer-info (char-code value)))))
     (#\D (u2 (pool-index pool (make-double-info value))))
     (#\F (u2 (pool-index pool (make-float-info value))))
     (#\L (u2 (pool-index pool (make-long-info value))))
     (#\s (u2 (pool-index pool (make-utf8-info value))))
     (#\e (destructuring-bind (type const) value
	    (list
	     (u2 (pool-index pool (make-utf8-info type)))
	     (u2 (pool-index pool (make-utf8-info const))))))
     (#\@ (byte-list value pool))
     (#\[ (let ((values value))
	    (list
	     (u2 (length values))
	     (loop for (tag value) in values
		   collect (write-element-value tag value pool))))))))

(defun parse-element-value (byte-stream pool-array)
  (let ((tag (code-char (parse-u1 byte-stream)))
	(value))
    (flet ((pool-lookup ()
	     (aref pool-array (parse-u2 byte-stream))))
      (setf value
	    (ccase tag
	      ((#\B #\I #\S #\Z)
	       (integer-info-value (pool-lookup)))
	      (#\C (code-char (integer-info-value (pool-lookup))))
	      (#\D (double-info-ieee-bits (pool-lookup)))
	      (#\F (float-info-ieee-bits (pool-lookup)))
	      (#\J (long-info-value (pool-lookup)))
	      (#\s (string-info-text (pool-lookup)))
	      (#\e (list
		    (utf8-info-text (pool-lookup))
		    (utf8-info-text (pool-lookup))))
	      (#\@ (parse-annotation byte-stream pool-array))
	      (#\[ (let ((count (parse-u2 byte-stream)))
		     (loop repeat count
			   collect (parse-element-value byte-stream pool-array))))))
      (list tag value))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (def-serialization element-value (tag value) byte-stream
    `(write-element-value ,tag ,value (constant-pool))
    `(destructuring-bind (tag% value%)
	 (parse-element-value ,byte-stream (pool-array))
       (setf ,tag tag%
	     ,value value%)))

  (def-jstruct annotation (type element-value-pairs)
    (u2 (utf8-info type))
    (with-length u2 element-value-pairs (name tag value)
      (u2 (utf8-info name))
      (element-value tag value)))

  (def-serialization annotation (annotation) byte-stream
    `(byte-list ,annotation (constant-pool))
    `(setf ,annotation (parse-annotation ,byte-stream (pool-array)))))

(def-attribute runtime-visible-annotations
    "RuntimeVisibleAnnotations"
    (annotations)
  (with-length u2 annotations annotation
    (annotation annotation)))

(def-attribute runtime-invisible-annotations
    "RuntimeInvisibleAnnotations"
    (annotations)
  (with-length u2 annotations annotation
    (annotation annotation)))

(def-attribute runtime-visible-parameter-annotations
    "RuntimeVisibleParameterAnnotations"
    (parameters)
  (with-length u1 parameters annotations
    (with-length u2 annotations annotation
      (annotation annotation))))

(def-attribute runtime-invisible-parameter-annotations
    "RuntimeInvisibileParameterAnnotations"
    (parameters)
  (with-length u1 parameters annotations
    (with-length u2 annotations annotation
      (annotation annotation))))

#|
;; TODO: parse type annotations

(def-jstruct type-annotation
    (target-type target-info target-path type element-value-pairs)
  (u1 target-type)
  (? target-info)
  (? target-path)
  (u2 type)
  (with-length u2 element-value-pairs (name tag value)
    (u2 (utf8-info name))
    (element-value tag value)))

(def-attribute runtime-visible-type-annotations
    "RuntimeVisibleTypeAnnotations"
    (annotations)
  (with-length u2 annotations annotation
    (type-annotation annotation)))

(def-attribute runtime-invisible-type-annotations
    "RuntimeInvisibleTypeAnnotations"
    (annotations)
  (with-length u2 annotations annotation
    (type-annotation annotation)))
|#

(def-attribute annotation-default "AnnotationDefault" (tag value)
  (element-value tag value))

(def-attribute bootstrap-methods "BootstrapMethods" (methods)
  (with-length u2 methods (kind reference arguments)
    (u2 (method-handle-info kind reference))
    (with-length u2 arguments argument
      (u2 (pool-index argument)))))

(defparameter *parameter-modifiers*
  '((:final        #x0010)
    (:synthetic    #x1000)
    (:mandated     #x8000)))

(def-attribute method-parameters "MethodParameters" (parameters)
  (with-length u1 parameters (name access-flags)
    (u2 (utf8-info name))
    (u2 (access-modifiers access-flags *parameter-modifiers*))))

(defparameter *module-modifiers*
  '((:open         #x0020)
    (:synthetic    #x1000)
    (:mandated     #x8000)))

(defparameter *require-modifiers*
  '((:transitive   #x0020)
    (:static-phase #x0040)
    (:synthetic    #x1000)
    (:mandated     #x8000)))

(defparameter *exports-modifiers*
  '((:synthetic    #x1000)
    (:mandated     #x8000)))

(defparameter *opens-modifiers*
  '((:synthetic    #x1000)
    (:mandated     #x8000)))

(def-attribute module "Module" (name flags version requires exports opens uses provides)
  (u2 (utf8-info name))
  (u2 (access-modifiers flags *module-modifiers*))
  (u2 (utf8-info version))
  (with-length u2 requires (module flags version)
    (u2 (module-info module))
    (u2 (access-modifiers flags *require-modifiers*))
    (u2 (utf8-info version)))
  (with-length u2 exports (package flags exports-to)
    (u2 (package-info package))
    (u2 (access-modifiers flags *exports-modifiers*))
    (with-length u2 exports-to (exports-to)
      (u2 (module-info exports-to))))
  (with-length u2 opens (package flags opens-to)
    (u2 (package-info package))
    (u2 (access-modifiers flags *opens-modifiers*))
    (with-length u2 opens-to (opens-to)
      (u2 (module-info opens-to))))
  (with-length u2 uses (uses)
    (u2 (class-info uses)))
  (with-length u2 provides (name provides-with)
    (u2 (class-info name))
    (with-length u2 provides-with (name)
      (u2 (class-info name)))))

(def-attribute module-packages "ModulePackages" (packages)
  (with-length u2 packages package
    (u2 (package-info package))))

(def-attribute module-main-class "ModuleMainClass" (main-class)
  (u2 (class-info main-class)))

(def-attribute nest-host "NestHost" (host-class)
  (u2 (class-info host-class)))

(def-attribute nest-members "NestMembers" (classes)
  (with-length u2 classes class
    (u2 (class-info class))))

(def-attribute record "Record" (components)
  (with-length u2 components (name descriptor attributes)
    (u2 (utf8-info name))
    (u2 (utf8-info descriptor))
    (with-length u2 attributes attribute
      (attribute attribute))))

(def-attribute permitted-subclasses "PermittedSubclasses" (classes)
  (with-length u2 classes class
    (u2 (class-info class))))
