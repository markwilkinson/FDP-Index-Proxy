class ErrorModel  # Notice, this is just a plain ruby object.
  include Swagger::Blocks

  swagger_schema :ErrorModel do
    key :required, %i[code message]
    property :code do
      key :type, :integer
      key :format, :int32
    end
    property :message do
      key :type, :string
    end
  end
end

# class AllResourcesResponse
#   include Swagger::Blocks

#   swagger_path '/resources' do
#     operation :get do
#       key :summary, 'Retrieve Resources'
#       key :description, 'retrieve all known Germplasm resources'
#       key :operationId, 'resources_retrieve'
#       key :tags, ['retrieve_resources']
#       key :produces, [
#         'text/html'
#       ]
#       parameter do
#         key :name, :guid
#         key :in, :query
#         key :description, 'FDP Index to process'
#         key :required, false
#         key :type, :string
#       end
#       response 200 do
#         key :description, 'discovered resources'
#       end
#     end
#   end
# end

# class OntologySearchResponse
#   include Swagger::Blocks

#   swagger_path '/ontology-search' do
#     operation :get do
#       key :summary, 'Ontology Search'
#       key :description, 'Retrieve the matching VP Resources from an ontology search against the dcat:theme and dcat:themeTaxonomy'
#       key :operationId, 'ontology_search'
#       key :tags, ['retrieve_ontology_search_results']
#       key :produces, [
#         'text/html'
#       ]
#       parameter do
#         key :name, :uri
#         key :in, :query
#         key :description, 'URI of the ontology term'
#         key :required, true
#         key :type, :string
#       end
#       response 200 do
#         key :description, 'discovered resources'
#       end
#     end
#   end
# end

# class KeywordSearchResponse
#   include Swagger::Blocks

#   swagger_path '/keyword-search' do
#     operation :get do
#       key :summary, 'Keyword Search'
#       key :description, 'Retrieve the matching VP Resources from an keyword search against the dcat:keyword'
#       key :operationId, 'keyword_search'
#       key :tags, ['retrieve_keyword_search_results']
#       key :produces, [
#         'text/html'
#       ]
#       parameter do
#         key :name, :keyword
#         key :in, :query
#         key :description, 'keyword to search with (case insensitive)'
#         key :required, true
#         key :type, :string
#       end
#       response 200 do
#         key :description, 'discovered resources'
#       end
#     end
#   end
# end
