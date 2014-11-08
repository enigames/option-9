(in-package :option-9)

(declaim (optimize (safety 3) (space 0) (speed 0) (debug 3)))

;; In general, we don't do anything special to any object that we create.
(defmethod make-instance-finish (nothing-to-do)
  nothing-to-do)

;; If any random entity sets a ttl-max and nothing more specific changes this
;; method, then assign a random ttl based upon the ttl-max.
(defmethod make-instance-finish :after ((s ephemeral))
  (when (not (null (ttl-max s)))
    (setf (ttl s) (random (ttl-max s))))
  s)

(defmethod make-instance-finish :after ((e entity))
  (setf (hit-points e) (max-hit-points e))
  e)

;; A powerup's ttl is the random amount up to ttl-max PLUS a constant second
(defmethod make-instance-finish :after ((p powerup))
  (when (ttl p)
    (incf (ttl p) 60))
  p)


;; XXX TODO: This needs to be figured out probably in SPAWN. Need(?) to add
;; a 'control' language to the object instances to allow spwn to handle
;; things like this. Maybe it should just BE lisp in the asset file?
;;
;; For enemy-3 there is only a 25 percent chance that it actually has
;; the shield specified in the option-9.dat file. If we decide it
;; shouldn't have a shield, the we set the main-shield to null which
;; makes the above generic method a noop.
(defmethod make-instance-finish :before ((ent enemy-3))
  ;; FIXME to deal with the fact I use turrets now.
  (when (<= (random 1.0) .75)
    (setf (ship-main-shield ent) nil))
  ent)


(defmethod make-instance-finish :after ((ent tesla-field))
  (setf (power-range ent) (power-range ent))
  (setf (power-lines ent) (power-lines ent))
  ent)

;; A factory constructor to make me a CLOS instance of any :instance
;; read into *assets*. Each entity also knows the game context
;; in which it will be placed. This allows the generic methods of
;; entities to inspect the game universe or insert effects into the
;; game like sparks.
(defun make-entity (instance &rest override-initargs)
  (multiple-value-bind (info present) (gethash instance (entities *assets*))
    (assert present)
    (assert instance)
    (let ((found-instance (cadr (assoc :instance info)))
          (cls (cadr (assoc :class info)))
          ;; Add in the instance name associated with this object too!
          (initargs (cons :instance-name
                          (cons instance
                                (cdr (assoc :initargs info))))))

      (assert (eq found-instance instance))
      (assert cls)

      ;; The COPY-SEQ is important because there is a potential to
      ;; modify the full-init args to replace certain named things
      ;; with their actual values.
      (let* ((full-args (copy-seq (append override-initargs initargs)))
             (roles (cadr (member :role full-args))))

        ;; Ensure any specified roles are actually valid!
        (assert (apply #'defined-roles-p *assets* roles))

        ;; Concerning the :geometry initarg value, replace named
        ;; geometries with real geometries from the cache. Otherwise,
        ;; make-instance the form found assuming it is an in-place
        ;; geometry specification.
        (let* ((?geometry (member :geometry full-args))
               (?geometry-name (cadr ?geometry)))
          ;; Only mess with the ?geometry initializer if we have one at all.
          (when ?geometry
            (if (and ?geometry-name (symbolp ?geometry-name))
                ;; Ok, we found a geometry-name, replace it with an actual
                ;; geometry object constructed form the initializers
                (multiple-value-bind (geometry presentp)
                    (gethash ?geometry-name (geometries *assets*))
                  (when (not presentp)
                    (error "Cannot find geometry-name ~A in the assets!"
                           ?geometry-name))
                  ;; Replace the copy-seq'ed full-args entry for the
                  ;; :geometry initarg to be the actual geometry instead
                  ;; of its name.
                  (setf (cadr ?geometry)
                        (apply #'make-instance 'geometry geometry)))
                ;; Ok, we have an inplace form, so just convert it.
                (setf (cadr ?geometry)
                      (apply #'make-instance 'geometry (cadr ?geometry))))))

        (make-instance-finish
         ;; The values of the override arguments are accepted
         ;; first when in a left to right ordering in the
         ;; argument list in concordance with the ANSI spec.
         (apply #'make-instance cls :game-context *game* full-args))))))

(defun insts/equiv-choice (ioi/e)
  "Given an instance equivalence class, select a random :instance from it.
Given an :instance name, just return it."
  (multiple-value-bind (instances presentp)
      (gethash ioi/e (insts/equiv *assets*))
    (if presentp
        (svref instances (random (length instances)))
        ioi/e)))

(defun defined-roles-p (assets &rest roles)
  (dolist (role roles)
    (multiple-value-bind (value presentp)
        (gethash role (defined-roles assets))
      (declare (ignore value))
      (when (not presentp)
        (return-from defined-roles-p nil))))
  t)

(defun specialize-generic-instance-name (context-instance-name
                                         generic-instance-name)
  "Given a CONTEXT instance-name keyword (like :player-1), lookup the
NAME, which is a generic instance name keyword (like :hardnose-shot),
and return a KEYWORD which is either the specialized name (such
as :player-1-hardnose-shot), or the original GENERIC-INSTANCE-NAME if
no specialization was found."
  (multiple-value-bind (cin-hash presentp)
      (gethash context-instance-name (instance-specialization-map *assets*))

    (unless presentp
      (return-from specialize-generic-instance-name generic-instance-name))

    (multiple-value-bind (spec-name-list presentp)
        (gethash generic-instance-name cin-hash)

      (unless presentp
        (return-from specialize-generic-instance-name generic-instance-name))

      ;; Until I possibly extend the spec-name-lists, just return the
      ;; first one.
      (car spec-name-list))))

;; This takes a relative filename based at the installation location
;; of the package.
(defun load-dat-file (filename)
  (let ((entity-hash (make-hash-table :test #'eq))
        (geometry-hash (make-hash-table :test #'eq))
        (instance-equivalences (make-hash-table :test #'eq))
        (instance-specializations (make-hash-table :test #'eq))
        (defined-roles (make-hash-table :test #'eq))
        (collision-plan nil)
        (entities
         (with-open-file (strm
                          ;; We'll look for the data file either in
                          ;; the current working directory, or at the
                          ;; ASDF install location.
                          (or (probe-file filename)
                              (asdf:system-relative-pathname
                               :option-9 filename))
                          :direction :input
                          :if-does-not-exist :error)
           ;; Read the symbols from the point of view of this package
           ;; so later when we make-instance it'll work even if the
           ;; user only "used" our package.
           (let ((*package* (find-package 'option-9)))
             (eval (read strm))))))

    ;; Ensure the thing we expect to be there actually are.
    (assert (member :defined-roles entities))
    (assert (member :collision-plan entities))
    (assert (member :instance-equivalence entities))
    (assert (member :instance-specialization-map entities))
    (assert (member :geometries entities))
    (assert (member :entities entities))

    ;; TODO typechecking and loading are intermixed. I probably can do
    ;; type checking after loading if I'm careful. Need to implement
    ;; that....

    ;; Consume the defined roles
    (loop for i in (cadr (member :defined-roles entities)) do
         (setf (gethash i defined-roles) t))

    ;; Consume and validate the collision-plan
    (setf collision-plan (cadr (member :collision-plan entities)))
    (dolist (plan collision-plan)
      ;; Check that all roles are currently defined.
      (destructuring-bind (fists faces) plan
        (loop for fist in fists do
             (assert (member fist (cadr (member :defined-roles entities)))))
        (loop for face in faces do
             (assert (member face (cadr (member :defined-roles entities)))))))

    ;; Consume the equivalence classes
    (loop for i in (cadr (member :instance-equivalence entities)) do
         (setf (gethash (car i) instance-equivalences) (cadr i)))

    ;; Consume the instance specialization map and convert it into a hash of
    ;; hashes.
    (loop for inst in (cadr (member :instance-specialization-map entities)) do
         (destructuring-bind (context-name mappings) inst
           (let ((spec-hash (make-hash-table :test #'eq)))
             (loop for entry in mappings do
                  (destructuring-bind (generic-name spec-name-list) entry
                    (setf (gethash generic-name spec-hash) spec-name-list)))
             (setf (gethash context-name instance-specializations) spec-hash))))

    ;; Consume the geometry information by processing each file in the
    ;; :geometries list, rip all geometries out and insert it into the
    ;; geometry-hash named by the supplied name associated with the
    ;; geometry.
    (let ((geometry-files (cadr (member :geometries entities))))
      (when geometry-files
        (dolist (geometry-file geometry-files)
          (let ((geometries
                 (with-open-file (gstrm
                                  (or (probe-file geometry-file)
                                      (asdf:system-relative-pathname
                                       :option-9 geometry-file))
                                  :direction :input
                                  :if-does-not-exist :error)
                   (let ((*package* (find-package 'option-9)))
                     (eval (read gstrm))))))
            ;; Insert all geometry forms into the geometry hash keyed
            ;; by the name of the form and whose value is the geometry
            ;; form.
            (loop for (geometry-name geometry) in geometries do
               ;; check to make sure they are all uniquely named
                 (multiple-value-bind (entry presentp)
                     (gethash geometry-name geometry-hash)
                   (declare (ignore entry))
                   (when presentp
                     (error "Geometry name ~A is not unique!" geometry-name)))
               ;; Poke it into the hash table if it is good.
                 (setf (gethash geometry-name geometry-hash) geometry))))))

    ;; Consume the entities into a hash indexed by the :instance in the form.
    (loop for i in (cadr (member :entities entities)) do
       ;; If :geometry exists in the initiargs and it is a symbol,
       ;; ensure it is defined in the geometry-hash
         (let* ((initargs (assoc :initargs i))
                (geometry-name (cadr (member :geometry initargs))))
           (when (and geometry-name (symbolp geometry-name))
             (multiple-value-bind (entry presentp)
                 (gethash geometry-name geometry-hash)
               (declare (ignore entry))
               (unless presentp
                 (error "Entity instance ~A uses a :geometry symbol ~(~S~) which does not exist in the geometry hash table!"
                        i geometry-name)))))
       ;; If the typecheck passed, store it!
         (setf (gethash (cadr (assoc :instance i)) entity-hash) i))


    ;; Create the master object which holds all the assets.
    (make-instance 'assets
                   :defined-roles defined-roles
                   :collision-plan collision-plan
                   :entities entity-hash
                   :geometries geometry-hash
                   :insts/equiv instance-equivalences
                   :instance-specialization-map instance-specializations)))
