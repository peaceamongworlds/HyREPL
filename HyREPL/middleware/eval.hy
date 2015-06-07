(import types sys threading [queue [Queue]] traceback [io [StringIO]])
(import ctypes)

(import
  [hy.importer [ast-compile hy-eval]]
  [hy.lex [tokenize]]
  [hy.lex.exceptions [LexException]])

(import
  [HyREPL.workarounds [get-workaround]]
  [HyREPL.ops [ops find-op]])
(require HyREPL.ops)


(defclass HyReplSTDIN [Queue]
  ; """This is hack to override sys.stdin."""
  [[--init--
    (fn [self write]
      (.--init-- (super))
      (setv self.writer write)
      None)]
   [readline
    (fn [self]
      (self.writer {"status" ["need-input"]})
      (.join self)
      (.get self))]])


(def eval-module (types.ModuleType "__main__")) ; Module context for evaluations


(defn async-raise [tid exc]
  (let [[res (ctypes.pythonapi.PyThreadState-SetAsyncExc (ctypes.c-long tid) (ctypes.py-object exc))]]
    (cond
      [(= res 0) (raise (ValueError (.format "Thread ID does not exist: {}" tid)))]
      [(> res 1)
       (do
         (ctypes.pythonapi.PyThreadState-SetAsyncExc tid 0)
         (raise (SystemError "PyThreadState-SetAsyncExc failed")))])))


(defclass InterruptibleEval [threading.Thread]
  ; """Repl simulation. This is a thread so hangs don't block everything."""
  [[--init--
     (fn [self msg session writer]
       (.--init-- (super))
       (setv self.writer writer)
       (setv self.msg msg)
       (setv self.session session)
       (setv sys.stdin (HyReplSTDIN writer))
       ; we're locked under self.session.lock, so modification is safe
       (setv self.session.eval-id (.get msg "id"))
       None)]
   [raise-exc
    (fn [self exc]
      (assert (.isAlive self) "Trying to raise exception on dead thread!")
      (for [(, tid tobj) (.items threading.-active)]
        (when (is tobj self)
          (async-raise tid exc)
          (break))))]
   [terminate
    (fn [self]
      (.raise-exc self SystemExit))]
   [run
     (fn [self]
       (let [[code (get self.msg "code")]
             [oldout sys.stdout]]
         (try
           (setv self.tokens (tokenize code))
           (catch [e Exception]
             (.format-excp self (sys.exc-info))
             (self.writer {"status" ["done"] "id" (.get self.msg "id")}))
           (else
             ; TODO: add 'eval_msg' updates too the current session
             (for [i self.tokens]
               (let [[p (StringIO)]]
                 (try
                   (do
                     (setv sys.stdout (StringIO))
                     (.write p (str (hy-eval i eval-module.--dict-- "__main__"))))
                   (except [e Exception]
                     (setv sys.stdout oldout)
                     (.format-excp self (sys.exc-info)))
                   (else
                     (self.writer {"value" (.getvalue p) "ns" (.get self.msg "ns" "Hy")})
                     (when (and (= (.getvalue p) "None") (bool (.getvalue sys.stdout)))
                       (self.writer {"out" (.getvalue sys.stdout)}))))))
             (setv sys.stdout oldout)
             (self.writer {"status" ["done"]})))))]
   [format-excp
     (fn [self trace]
       (let [[exc-type (first trace)]
             [exc-value (second trace)]
             [exc-traceback (get trace 2)]]
         (setv self.session.last-traceback exc-traceback)
         (self.writer {"status" ["eval-error"]
                      "ex" (. exc-type --name--)
                      "root-ex" (. exc-type --name--)
                      "id" (.get self.msg "id")})
         (when (instance? LexException exc-value)
           (when (is exc-value.source None)
             (setv exc-value.source ""))
           (setv exc-value (.format "LexException: {}" exc-value.message)))
         (self.writer {"err" (.strip (str exc-value))})))]])


(defop eval [session msg transport]
       {"doc" "Evaluates code."
        "requires" {"code" "The code to be evaluated"
                    "session" "The ID of the session in which the code will be evaluated"}
        "optional" {"id" "An opaque message ID that will be included in the response"}
        "returns" {"ex" "Type of the exception thrown, if any. If present, `value` will be absent."
                   "ns" "The current namespace after the evaluation of `code`. For HyREPL, this will always be `Hy`."
                   "root-ex" "Same as `ex`"
                   "value" "The values returned by `code` if execution was successful. Absent if `ex` and `root-ex` are present"}}
       (let [[w (get-workaround (get msg "code"))]]
         (assoc msg "code" (w session msg))
         (with [session.lock]
           (when (and (is-not session.repl None) (.is-alive session.repl))
             (.join session.repl))
           (setv session.repl
             (InterruptibleEval msg session
                                (fn [x]
                                  (assoc x "id" (.get msg "id"))
                                  (.write session x transport))))
           (.start session.repl))))


(defop interrupt [session msg transport]
       {"doc" "Interrupt a running eval"
        "requires" {"session" "The session id used to start the eval to be interrupted"}
        "optional" {"interrupt-id" "The ID of the eval to interrupt"}
        "returns" {"status" "\"interrupted\" if an eval was interrupted, \"session-idle\" if the session is not evaluating code at"
                   "the moment, \"interrupt-id-mismatch\" if the session is currently evaluating code with a different ID than the"
                   "specified \"interrupt-id\" value"}}
       (.write session {"id" (.get msg "id")
                        "status"
                        (with [session.lock]
                          (cond
                            [(or (is session.repl None) (not (.is-alive session.repl)))
                             "session-idle"]
                            [(!= session.eval-id (.get msg "interrupt-id"))
                             "interrupt-id-mismatch"]
                            [True
                             (do
                               (.terminate session.repl)
                               (.join session.repl)
                               "interrupted")]))}
               transport)
       (.write session
               {"status" ["done"]
                "id" (.get msg "id")}
               transport))


(defop load-file [session msg transport]
       {"doc" "Loads a body of code. Delegates to `eval`"
       "requires" {"file" "full body of code"}
       "optional" {"file-name" "name of the source file, for example for exceptions"
                  "file-path" "path to the source file"}
       "returns" (get (:desc (get ops "eval")) "returns")}
       (let [[code (-> (get msg "file")
                     (.split " " 2)
                     (get 2))]]
         (print (.strip code) :file sys.stderr)
         (assoc msg "code" code)
         (del (get msg "file"))
         ((find-op "eval") session msg transport)))
