(component :Salesforce)

(use '[camel_googlesheets_resolver.core])

(entity
 :Quote
 {:meta {:inferred true}})

(dataflow
 [:after :create :Quote]
 [:eval '(println "Created: " :Instance)]
 {:Camel.Googlesheets.Core/Spreadsheet
  {:title :Instance.Name
   :data :Instance}})

(dataflow
 [:after :delete :Quote]
 [:eval '(println "Deleted: " :Instance)])

(require '[camel_sfdc_resolver.core])

(resolver
 :Salesforce/Resolver
 {:type :Camel.Sfdc.Core/Resolver :paths [:Salesforce/Quote]})
