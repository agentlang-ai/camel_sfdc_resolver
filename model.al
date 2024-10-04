{:name :Camel.Sfdc.Resolver
 :version "0.0.1"
 :agentlang-version "0.6.0-alpha3"
 :dependencies (quote [[org.apache.camel/camel-main "4.6.0"]
                 [org.apache.camel/camel-jackson "4.6.0"]
                 [org.apache.camel/camel-salesforce "4.6.0"]
                 [com.github.agentlang-ai/camel-resolver "0.0.1"]])
 :components [:Camel.Sfdc.Resolver.Core]
 :config-entity :Camel.Sfdc.Resolver.Core/Config}
