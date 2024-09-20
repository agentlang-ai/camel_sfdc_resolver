(component
 :Camel.Sfdc.Resolver.Core
 {:clj-import
  (quote [(:require [clojure.string :as s]
              [selmer.parser :as st]
              [agentlang.util :as u]
              [agentlang.util.logger :as log] 
              [agentlang.store.util :as stu]
              [agentlang.component :as cn]
              [agentlang.evaluator :as ev]
              [agentlang.lang.internal :as li]
              [agentlang.datafmt.json :as json]
              [agentlang.evaluator :as ev]
              [agentlang.resolver.camel.core :as camel])
    (:import [org.apache.camel Component]
             [org.apache.camel.component.salesforce SalesforceComponent AuthenticationType])])})

(entity
 :Config
 {:meta {:inherits :Agentlang.Kernel.Lang/Config}
  :InstanceUrl :String
  :ApexEndpoint {:type :String :optional true}
  :ClientId :String
  :ClientSecret :String})
 
(def component-cache (atom nil))

(defn ^Component get-component []
  (or @component-cache
      (let [config (ev/fetch-model-config-instance :Camel.Sfdc.Resolver)
            ^SalesforceComponent sfc (SalesforceComponent.)
            inst-url (:InstanceUrl config)]
        (when (seq inst-url)
          (.setClientId sfc (:ClientId config))
          (.setClientSecret sfc (:ClientSecret config))
          (.setAuthenticationType sfc (AuthenticationType/valueOf "CLIENT_CREDENTIALS"))
          (.setInstanceUrl sfc inst-url)
          (.setLoginUrl sfc inst-url)
          (reset! component-cache sfc)
          sfc))))

(def endpoint-templates
  {:create "salesforce:createSObject?apiVersion=59.0&rawPayload=true&format=JSON&sObjectName={{sObjectName}}"
   :query "salesforce:query?apiVersion=59.0&rawPayload=true&format=JSON&sObjectName={{sObjectName}}"
   :apexCall "salesforce:apexCall{{restEndpoint}}/v3/OrderPreValidation?apexMethod=POST&rawPayload=true"})

(def ^:private log-prefix "sfdc resolver: ")

(defn sf-create [instance]
  (log/debug (str log-prefix "create instance - " instance))
  (let [camel-component (get-component)
        [_ n] (li/split-path (cn/instance-type instance))
        ep (st/render (:create endpoint-templates) {:sObjectName (name n)})
        result (camel/exec-route {:endpoint ep
                                  :user-arg (json/encode
                                             (dissoc
                                              (cn/instance-attributes instance)
                                              li/id-attr))
                                  :camel-component camel-component})
        r (when result (json/decode result))]
    (log/debug (str log-prefix "create instance result - " result))
    (when (:success r) (assoc instance :Id (:id r)))))

(defn lookup-all [[_ sobj-name :as entity-name]]
  (str "SELECT FIELDS(ALL) FROM " (name sobj-name) " LIMIT 200"))

(defn lookup-by-expr [[_ sobj-name :as entity-name]
                       where-clause]
  (str "SELECT FIELDS(ALL) FROM " (name sobj-name)
       " WHERE " where-clause " LIMIT 200"))

(defn as-raw-sql-val [v]
  (if (or (string? v) (number? v) (boolean? v))
    v
    (stu/encode-clj-object v)))

(defn as-sql-expr [[opr attr v]]
  [(str (name attr) " " (name opr) " ?") [(as-raw-sql-val v)]])

(defn replace-placeholders [sql params]
  (reduce (fn [s p]
            (s/replace-first
             s #"\?"
             (if (string? p)
               (str "'" p "'")
               (str p))))
          sql params))

(defn sf-apex-query [[entity-name {clause :where} :as param]]
  (let [config (ev/fetch-model-config-instance :Camel.Sfdc.Resolver)
        apex-endpoint (:ApexEndpoint config)
        _ (when-not apex-endpoint (u/throw-ex "SFDC ApexEndpoint is not set"))
        k (second clause)
        v (last clause)
        _ (log/debug (str log-prefix "sf-apex-query " entity-name clause apex-endpoint))
        res (camel/exec-route
             {:endpoint
              (st/render
               (:apexCall endpoint-templates)
               {:restEndpoint apex-endpoint})
              :user-arg (json/encode {k v})
              :camel-component (get-component)})
        _ (log/debug (str log-prefix "sf-apex-query result " res))
        res (json/decode res)]
    (if (= (:status res) "Success")
      [(cn/make-instance entity-name (assoc res k v))]
      (do (log/error (str log-prefix  "sf-apex-query error " 
                          entity-name " - " clause " - " apex-endpoint "\nresponse: " res))
        (u/throw-ex (:errorDescription (:error res)))))))

(defn sf-query [[entity-name {clause :where} :as param]]
  (log/debug (str log-prefix "query " param))
  (try 
    (let [camel-component (get-component)
          soql (cond
                 (or (= clause :*) (nil? (seq clause)))
                 (lookup-all entity-name)

                 :else
                 (let [opr (first clause)
                       where-clause (case opr
                                      (:and :or)
                                      (let [sql-exp (mapv as-sql-expr (rest clause))
                                            exps (mapv first sql-exp)
                                            params (flatten (mapv second sql-exp))]
                                        (replace-placeholders
                                         (s/join (str " " (s/upper-case (name opr)) " ") exps)
                                         params))
                                      (let [[s params] (as-sql-expr clause)]
                                        (replace-placeholders s params)))]
                   (lookup-by-expr entity-name where-clause)))
          [_ n] entity-name
          ep (st/render
              (:query endpoint-templates)
              {:sObjectName (name n)})
          _ (log/debug (str log-prefix "generated SOQL - " soql))
          result (camel/exec-route {:endpoint ep
                                    :user-arg soql
                                    :camel-component camel-component})
          recs (:records (json/decode result))
          _ (log/debug (str log-prefix "query result: " param "\nresponse: " result))]
      (when (or (nil? recs) (empty? recs))
        (log/error (str log-prefix "query empty result: " param "\nresponse: " result)))
      (mapv (partial cn/make-instance entity-name) recs))
      (catch Exception ex
        (log/error (str log-prefix "query exception: " param "\nresponse: " ex))
        (throw ex))))

(def registered-paths (atom #{}))

(defn make-full-path [entity-name]
  (when-let [[c n] (first (filter (fn [[_ en]] (= entity-name en)) @registered-paths))]
    (li/make-path c n)))

(defn crud-info [subs-response]
  (let [payload (get-in subs-response [:data :payload])
        evt (:ChangeEventHeader payload)
        tag (keyword (s/lower-case (:changeType evt)))
        entity-name (make-full-path (keyword (:entityName evt)))]
    (when entity-name
      [tag entity-name (cn/make-instance {entity-name payload})])))

(def ^:private subscribed (atom nil))

(defn subscribe-to-change-events []
  (when-not @subscribed
    (camel/exec-route
     {:endpoint "salesforce:subscribe:/data/ChangeEvents?rawPayload=true"
      :camel-component (get-component)
      :callback #(let [r (json/decode %)
                       [tag entity-name inst :as cinfo] (crud-info r)]
                   (when cinfo
                     (log/info (str log-prefix "change event for - " cinfo))
                     (cn/force-fire-post-event ev/eval-all-dataflows tag entity-name inst)))}
     false)
    (reset! subscribed true))
  true)

(defn sf-on-set-path [[tag path]]
  (when (= tag :override)
    (-> path cn/disable-post-events cn/with-external-schema))
  (swap! registered-paths conj (li/split-path path))
  path)

(resolver
 :Camel.Sfdc.Resolver.Core/Resolver
 {:require {:pre-cond subscribe-to-change-events}
  :with-methods
  {:create sf-create
   :query sf-query
   :on-set-path sf-on-set-path}})

(resolver
 :Camel.Sfdc.Resolver.Core/ApexResolver
 {:require {:pre-cond subscribe-to-change-events}
  :with-methods
  {:query sf-apex-query}})
