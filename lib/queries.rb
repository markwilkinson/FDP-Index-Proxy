NAMESPACES = "PREFIX ejpold: <http://purl.org/ejp-rd/vocabulary/>
  PREFIX ejpnew: <https://w3id.org/ejp-rd/vocabulary#>
  PREFIX dcat: <http://www.w3.org/ns/dcat#>
  PREFIX dc: <http://purl.org/dc/terms/>
  PREFIX fdp: <https://w3id.org/fdp/fdp-o#>
  PREFIX vcard: <http://www.w3.org/2006/vcard/ns#>
  ".freeze
# VPCONNECTION = "ejpold:vpConnection ejpnew:vpConnection dcat:theme dcat:themeTaxonomy".freeze
# VPDISCOVERABLE = "ejpold:VPDiscoverable ejpnew:VPDiscoverable".freeze
# VPANNOTATION = "dcat:theme".freeze
VPCONNECTION = "ejpnew:vpConnection".freeze
VPDISCOVERABLE = "ejpnew:VPDiscoverable".freeze
VPANNOTATION = "dcat:theme".freeze

def find_subject_uri_query(graph:, type:)
  warn "TYPE:", type

  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?s WHERE
    {
     ?s a dcat:#{type}
    }
    ")
  query.execute(graph).map { |result| result[:s].to_s }
end

def find_dcat_classes(graph:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?s ?type WHERE
    { VALUES ?type {fdp:FAIRDataPoint dcat:Catalog dcat:Dataset dcat:Distribution dcat:DataService}
     ?s a ?type
    }
    ")
  query.execute(graph).map { |result| [result[:s].to_s, result[:type].to_s] }
end

def lookup_title(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?title WHERE
    {
     <#{resource}> dc:title ?title .
    }
    ")
  result = query.execute(graph)
  return result.first[:title] if result&.first

  nil
end

def lookup_publisher(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?pred ?contact WHERE
    { VALUES ?pred {dc:publisher }
     OPTIONAL {<#{resource}> ?pred ?contact }.
    }
    ")
  query.execute(graph)  # should only be one!
end

def lookup_contact(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?contact ?url ?email ?name WHERE
    {
     <#{resource}> dcat:contactPoint ?contact .
     OPTIONAL {?contact vcard:url ?url} .
     OPTIONAL {?contact vcard:hasEmail ?email} .
     OPTIONAL {?contact vcard:fn ?name} .

    }
    ")
  query.execute(graph)  # should only be one!
end

# TODO:   At the moment, this does not support multi-parenting.  Maybe it should?
def lookup_parent(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?parent ?pred ?type WHERE
    { VALUES ?pred {fdcat:service dcat:accessService dcat:catalog dcat:dataset dcat:distribution }
     ?parent a ?type .
     ?parent ?pred <#{resource}> .
    }
    ")
  result = query.execute(graph).first  # should only be one!
  return nil unless result

  result[:parent].to_s
end

def clarify_data_service_parent(graph:, service:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?parent ?pred ?type WHERE
    { VALUES ?pred {fdcat:service dcat:accessService}
     ?parent a ?type .
     ?parent ?pred <#{service}> .
    }
    ")
  result = query.execute(graph).first  # should only be one!
  return [nil, nil] unless result

  _pred = result[:pred].to_s
  parent = result[:parent].to_s
  type = result[:type].to_s

  return ["DataService1", parent] if type =~ /Catalog/

  ["DataService2", parent]
end

def triplify(s, p, o, repo, datatype = nil)
  s = s.strip if s.instance_of?(String)
  p = p.strip if p.instance_of?(String)
  o = o.strip if o.instance_of?(String)
  warn "subject #{s} predicate #{p} object #{o}"
  unless s.respond_to?("uri")

    if s.to_s =~ %r{^\w+:/?/?[^\s]+}
      s = RDF::URI.new(s.to_s)
    else
      abort "Subject #{s} must be a URI-compatible thingy"
    end
  end

  unless p.respond_to?("uri")

    if p.to_s =~ %r{^\w+:/?/?[^\s]+}
      p = RDF::URI.new(p.to_s)
    else
      abort "Predicate #{p} must be a URI-compatible thingy"
    end
  end

  unless o.respond_to?("uri")
    o = if datatype
          RDF::Literal.new(o.to_s, datatype: datatype)
        elsif o.to_s =~ %r{\A\w+:/?/?\w[^\s]+}
          RDF::URI.new(o.to_s)
        elsif o.to_s =~ /^\d{4}-[01]\d-[0-3]\dT[0-2]\d:[0-5]\d/
          RDF::Literal.new(o.to_s, datatype: RDF::XSD.date)
        elsif o.to_s =~ /^[+-]?\d+\.\d+/ && o.to_s !~ /[^\+\-\d\.]/  # has to only be digits
          RDF::Literal.new(o.to_s, datatype: RDF::XSD.float)
        elsif o.to_s =~ /^[+-]?[0-9]+$/ && o.to_s !~ /[^\+\-\d\.]/  # has to only be digits
          RDF::Literal.new(o.to_s, datatype: RDF::XSD.int)
        else
          RDF::Literal.new(o.to_s, language: :en)
        end
  end

  triple = RDF::Statement(s, p, o)
  repo.insert(triple)

  true
end

def self.triplify_this(s, p, o, repo)
  triplify(s, p, o, repo)
end

def find_discoverables_query(graph:)
  vpd = SPARQL.parse("
      #{NAMESPACES}
      SELECT DISTINCT ?s ?t ?title ?contact ?servicetype WHERE
      {
        VALUES ?connection { #{VPCONNECTION} }
        VALUES ?discoverable { #{VPDISCOVERABLE} }

        ?s  ?connection ?discoverable ;
            dc:title ?title ;
            a ?t .

        OPTIONAL{?s dcat:contactPoint ?c .
                 ?c <http://www.w3.org/2006/vcard/ns#url> ?contact }.
        OPTIONAL{?s dc:type ?servicetype }.

      }
      ")
  graph.query(vpd)
end

def keyword_search_query(graph:, keyword:)
  vpd = SPARQL.parse("
      #{NAMESPACES}

      SELECT DISTINCT ?s ?t ?title ?contact WHERE
      {
        VALUES ?connection { #{VPCONNECTION} }
        VALUES ?discoverable { #{VPDISCOVERABLE} }
        ?s  ?connection ?discoverable ;
            dc:title ?title ;
            a ?t .
        OPTIONAL{?s dcat:contactPoint ?c .
                 ?c <http://www.w3.org/2006/vcard/ns#url> ?contact } .
            {
                VALUES ?searchfields { dc:title dc:description dc:keyword }
                ?s ?searchfields ?kw
                FILTER(CONTAINS(lcase(?kw), '#{keyword}'))
            }
      }")
  # warn "keyword search query #{vpd.to_sparql}"
  # warn "graph is #{@graph.size}"
  graph.query(vpd)
end

def ontology_search_query(graph:, uri:)
  vpd = SPARQL.parse("

      #{NAMESPACES}

      SELECT DISTINCT ?s ?t ?title ?contact WHERE
      {
        VALUES ?connection { #{VPCONNECTION} }
        VALUES ?discoverable { #{VPDISCOVERABLE} }

        ?s  ?connection ?discoverable ;
            dc:title ?title ;
            a ?t .
        OPTIONAL{?s dcat:contactPoint ?c .
                 ?c <http://www.w3.org/2006/vcard/ns#url> ?contact } .
            {
                ?s dcat:theme ?theme .
                FILTER(CONTAINS(str(?theme), '#{uri}'))
            }
      }")

  graph.query(vpd)
end

def verbose_annotations_query(graph:)
  # TODO: This does not respect vpdiscoverable...
  vpd = SPARQL.parse("
      #{NAMESPACES}
      SELECT DISTINCT ?annot WHERE
      { VALUES ?annotation { dcat:theme dcat:themeTaxonomy }
        ?s  ?annotation ?annot .
        }")
  graph.query(vpd)
end

def keyword_annotations_query(graph:)
  vpd = SPARQL.parse("
      #{NAMESPACES}
      select DISTINCT ?kw WHERE
      { VALUES ?searchfields { dc:keyword }
      ?s ?searchfields ?kw .
      }")
  graph.query(vpd)
end

def collect_data_services_query(graph:)
  vpd = SPARQL.parse("

      #{NAMESPACES}

      SELECT DISTINCT ?type WHERE
      {
        VALUES ?connection { #{VPCONNECTION} }
        VALUES ?discoverable { #{VPDISCOVERABLE} }

        ?s  ?connection ?discoverable ;
            a dcat:DataService .
            {
                ?s dc:type ?type .
            }
      }")
  graph.query(vpd)
end
