(in-package :cl-svg-polygon)

(define-condition not-an-object (simple-condition) ())

(defun get-points-from-ellipse (x y rx ry &key (curve-resolution 20))
  "Calculate curve-resolution points along an ellipse. Can be used for circles
  too (when rx == ry)."
  (let ((points (make-array curve-resolution)))
    (dotimes (i curve-resolution)
      (let ((rad (* i (/ (* 2 PI) curve-resolution))))
        (setf (aref points i)
              (list (coerce (+ x (* (cos rad) rx)) 'single-float)
                    (coerce (+ y (* (sin rad) ry)) 'single-float)))))
    points))

(defmacro with-plist-string-reads (plist bindings &body body)
  "Helper macro to make convert-to-points much more readable. Basically wraps
  around reading values from a string in a plist and binding the result to a
  variable:
  
    (with-plist-string-reads my-plist ((x :x) (y :y))
      (+ x y))
  
  Expands to:

    (let ((x (read-from-string (getf my-plist :x)))
          (y (read-from-string (getf my-plist :y))))
      (+ x y))

  Much cleaner."
  `(let ,(loop for binding in bindings collect
          (list (car binding) `(read-from-string (getf ,plist ,(cadr binding)))))
     ,@body))

(defun convert-to-points (obj &key (curve-resolution 10))
  "Take an object loaded from and SVG file (most likely using parse-svg-nodes)
  and turn it into a set of points describing a polygon. Curves are
  approximated using :curve-resolution. The higher the resolution, the more
  accurate the curve will be. This works for paths with bezier curves as well
  as ellipses and circles."
  (case (intern (string-upcase (getf obj :type)) :cl-svg-polygon)
    (rect
      (with-plist-string-reads obj ((x :x) (y :y) (w :width) (h :height)) 
        (list :points (list (vector (list x y)
                                    (list (+ x w) y)
                                    (list (+ x w) (+ y h))
                                    (list x (+ y h)))))))
    (polygon
      (let* ((pairs (split-sequence:split-sequence #\space (getf obj :points)))
             (points (loop for pair in pairs
                           if (find #\, pair) collect (progn (setf (aref pair (search "," pair)) #\space)
                                                             (read-from-string (format nil "(~a)" pair))))))
        (list :points (list (coerce points 'vector)))))
    (path
      (multiple-value-bind (parts disconnected)
          (get-points-from-path (getf obj :d) :curve-resolution curve-resolution)
        (list :points parts :meta (list :disconnected disconnected))))
    (polyline
     (let* ((pairs (split-sequence:split-sequence #\space (getf obj :points)))
	    (points (loop for pair in pairs
			  if (find #\, pair) collect (progn (setf (aref pair (search "," pair)) #\space)
							    (read-from-string (format nil "(~a)" pair))))))
       (list :points (list (coerce points 'vector)))))
    (line
     (with-plist-string-reads obj ((x1 :x1) (y1 :y1) (x2 :x2) (y2 :y2))
       (list :points (list (vector (list x1 y1)
                                   (list x2 y2))))))
    (ellipse 
      (with-plist-string-reads obj ((x :cx) (y :cy) (rx :rx) (ry :ry))
        (list :points (list (get-points-from-ellipse x y rx ry :curve-resolution curve-resolution)))))
    (circle
      (with-plist-string-reads obj ((x :cx) (y :cy) (r :r))
        (list :points (list (get-points-from-ellipse x y r r :curve-resolution curve-resolution)))))
    (t
      (error 'not-an-object))))

(defun tagname (obj)
  "Get the tag name of an object."
  (if (listp obj)
      (tagname (car obj))
      obj))

(defun get-node-attr (node attr-name)
  "Given a node, get the attribute stored under attr-name."
  (let ((val nil))
    (dolist (attr (cadr node))
      (when (equal (car attr) attr-name)
        (setf val (cadr attr))
        (return)))
    val))

(defun parse-svg-nodes (nodes &key parent-group (next-id 0) save-attributes (group-id-attribute-name "id"))
  "Given an SVG doc read via xmls:parse, return two things:

    1. A list of plist objects describing ALL the objects found in the SVG file.
       Each object stores the group it's part of along with its attributes and
       transformations.
    2. A list of plist objects describing ALL the groups found, each storing its
       group id (created if not explicit) and any transformations that group has.
  
  The idea is that given this data, we can easily generate polygons for each
  object and then apply transformations to it starting with its top-level group
  and working down to the object's transformations itself."
  (let ((objs nil)
        (groups nil))
    (dolist (node (cddr nodes))
      (let ((tag (tagname node)))
        (if (equal tag "g")
            (let* ((gid (get-node-attr node group-id-attribute-name))
                   (gid (if gid gid (get-node-attr node "id")))
                   (gid (list (if gid gid (incf next-id))))
                   (full-gid (if parent-group
                                 (append parent-group gid)
                                 gid)))
              (multiple-value-bind (sub-nodes sub-groups) (parse-svg-nodes node
                                                                           :parent-group full-gid
                                                                           :next-id next-id
                                                                           :save-attributes save-attributes
                                                                           :group-id-attribute-name group-id-attribute-name)
                (setf objs (append sub-nodes objs))
                (push (list :group gid :transform (parse-transform (get-node-attr node "transform")) :groups sub-groups) groups)))
            (let* ((gid parent-group)
                   (obj (list :type tag :group gid))
                   (tagsym (intern (string-upcase tag) :cl-svg-polygon))
                   (attrs (append (case tagsym
                                    (rect (list "x" "y" "width" "height"))
                                    (polygon (list "points"))
				    (line (list "x1" "y1" "x2" "y2"))
				    (polyline (list "points"))
                                    (path (list "d"))
                                    (ellipse (list "cx" "cy" "rx" "ry"))
                                    (circle (list "cx" "cy" "r"))
                                    (t nil))
                                  save-attributes)))
              (when attrs
                (push (append obj (loop for attr in (append attrs (list "transform" "fill" "style" "opacity"))
                                        for val = (get-node-attr node attr)
                                        for parsed = (if (and val (equal attr "transform")) (parse-transform val) val)
                                        if parsed append (list (read-from-string (format nil ":~a" attr)) parsed)))
                      objs))))))
    (values objs groups)))

(defun file-contents (path)
  "Sucks up an entire file from PATH into a freshly-allocated string,
  returning two values: the string and the number of bytes read."
  (with-open-file (s path)
    (let* ((len (file-length s))
           (data (make-string len)))
      (values data (read-sequence data s)))))

(defun parse-svg-string (svg-str &key (curve-resolution 10) scale save-attributes (group-id-attribute-name "id"))
  "Parses an SVG string, creating the nodes and groups from the SVG, then
  converts each object into a set of points using the data in that object and
  the transformations from the groups the object belongs to (and the object's
  own transformations).

  SVG object curve resolutions can be set via :curve-resolution (the higher the
  value, the more accurate curves are)."
  (multiple-value-bind (nodes groups)
      (parse-svg-nodes (xmls:node->nodelist (xmls:parse svg-str)) :save-attributes save-attributes :group-id-attribute-name group-id-attribute-name)
    (remove-if
      'null
      (mapcar (lambda (node)
                (handler-case
                  (let* ((points-and-meta (convert-to-points node :curve-resolution curve-resolution))
                         (points-and-holes (getf points-and-meta :points))
                         (points (apply-transformations (car points-and-holes) node groups :scale scale))
                         (holes nil))
                    (dolist (hole (cdr points-and-holes))
                      (push (coerce (apply-transformations hole node groups :scale scale) 'vector) holes))
                    (append node (list :point-data (coerce points 'vector) :holes holes :meta (getf points-and-meta :meta))))
                  (not-an-object ()
                    nil)))
              nodes))))

(defun parse-svg-file (filename &key (curve-resolution 10) scale save-attributes (group-id-attribute-name "id"))
  "Simple wrapper around parse-svg-string.
  
  SVG object curve resolutions can be set via :curve-resolution (the higher the
  value, the more accurate curves are)."
  (parse-svg-string (file-contents filename) :curve-resolution curve-resolution :scale scale :save-attributes save-attributes :group-id-attribute-name group-id-attribute-name))


