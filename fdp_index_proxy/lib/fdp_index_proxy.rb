# frozen_string_literal: true

require_relative "fdp_index_proxy/version"
# require_relative "ontologyservers/bioregistry"
# require_relative  "ontologyservers/identifiers"
# require_relative  "ontologyservers/ebi_ontology"
# require_relative  "ontologyservers/ebi_ontology_v3"
# require_relative  "ontologyservers/ontobee"
# require_relative  "ontologyservers/etsi"
# require_relative  "ontologyservers/bio2rdf"
# require_relative  "ontologyservers/ncbo"
# require_relative  "ontologyservers/schema"
# require_relative  "ontologyservers/edam"

require_relative  "cache"
require_relative  "metadata_functions"

require "json"
require "linkeddata"
require "rest-client"
require "require_all"
require "rdf/vocab"

require_all "."

module FdpIndexProxy
  class Error < StandardError; end
  # Your code goes here...
end
