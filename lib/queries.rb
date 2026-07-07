# Namespace prefixes shared by all SPARQL queries in this file.
NAMESPACES = "PREFIX ejpold: <http://purl.org/ejp-rd/vocabulary/>
  PREFIX ejpnew: <https://w3id.org/ejp-rd/vocabulary#>
  PREFIX dcat: <http://www.w3.org/ns/dcat#>
  PREFIX dc: <http://purl.org/dc/terms/>
  PREFIX fdp: <https://w3id.org/fdp/fdp-o#>
  PREFIX vcard: <http://www.w3.org/2006/vcard/ns#>
  PREFIX ftr: <https://w3id.org/ftr#>
  PREFIX r3d: <http://www.re3data.org/schema/3-0#>".freeze

# Predicate that marks a resource as participating in VP (Virtual Platform) discovery.
# Only the current EJP-RD vocabulary URI is active; legacy variants are retained
# as comments for reference.
# VPCONNECTION = "ejpold:vpConnection ejpnew:vpConnection dcat:theme dcat:themeTaxonomy"
VPCONNECTION   = "ejpnew:vpConnection".freeze

# Class value that marks a resource as explicitly VP-discoverable.
# VPDISCOVERABLE = "ejpold:VPDiscoverable ejpnew:VPDiscoverable"
VPDISCOVERABLE = "ejpnew:VPDiscoverable".freeze

# Annotation predicate used for ontology-based VP discovery.
VPANNOTATION   = "dcat:theme".freeze

# Finds all subjects in +graph+ whose +rdf:type+ matches any of +type_uris+.
# Accepting the full candidate URIs directly (rather than reconstructing a
# +dcat:+ URI from a short name) lets callers match subjects typed with a
# non-DCAT-namespaced equivalent class (e.g. +ftr:Test+, which is
# +rdfs:subClassOf dcat:DataService+ but isn't itself a +dcat:+ URI).
#
# @param graph     [RDF::Graph]    the graph to query
# @param type_uris [Array<String>] full candidate type URIs
# @return [Array<String>] subject URIs as plain strings
def find_subject_uri_query(graph:, type_uris:)
  warn "TYPE_URIS:", type_uris
  warn "GRAPH:", graph

  return [] if type_uris.empty?

  values = type_uris.map { |u| "<#{u}>" }.join(" ")

  query_str = <<~SPARQL.strip
    #{NAMESPACES}
    SELECT DISTINCT ?s WHERE {
      VALUES ?type { #{values} }
      ?s a ?type .
    }
  SPARQL

  warn "EXECUTING QUERY:\n#{query_str}"

  SPARQL.parse(query_str).execute(graph).map { |result| result[:s].to_s }
end

# Returns every DCAT-typed (or DCAT-equivalent) resource in +graph+, covering
# the standard DCAT hierarchy, the FDP root class, and the FTR core classes
# that are recognized as DCAT equivalents (see {FDP::FTR_TYPE_EQUIVALENTS}).
# Used by {FDP#post_process} to iterate over all resources that need LDP
# container injection.
#
# @param graph [RDF::Graph] the graph to query
# @return [Array<Array(String, String)>] pairs of +[subject_uri, type_uri]+
def find_dcat_classes(graph:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?s ?type WHERE
    { VALUES ?type {fdp:FAIRDataPoint dcat:Catalog dcat:Dataset dcat:Distribution dcat:DataService
                     ftr:Test ftr:Metric ftr:Benchmark ftr:ScoringAlgorithm}
     ?s a ?type
    }
    ")
  query.execute(graph).map { |result| [result[:s].to_s, result[:type].to_s] }
end

# Looks up the +dc:title+ of +resource+.
#
# @param graph    [RDF::Graph] the graph to query
# @param resource [String]     URI of the resource
# @return [RDF::Term, nil] the title literal, or +nil+ if absent
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

# Looks up the +dc:publisher+ of +resource+.
#
# @param graph    [RDF::Graph] the graph to query
# @param resource [String]     URI of the resource
# @return [SPARQL::Client::Solutions] result rows with +:pred+ and +:contact+
def lookup_publisher(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?pred ?contact WHERE
    { VALUES ?pred {dc:publisher }
     OPTIONAL {<#{resource}> ?pred ?contact }.
    }
    ")
  query.execute(graph)
end

# Looks up the +dcat:contactPoint+ of +resource+ and its vCard sub-properties.
#
# @param graph    [RDF::Graph] the graph to query
# @param resource [String]     URI of the resource
# @return [SPARQL::Client::Solutions] rows with +:contact+, +:url+, +:email+, +:name+
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
  query.execute(graph)
end

# Finds the parent resource of +resource+ by locating any subject that uses a
# DCAT structural predicate to point at it.
#
# @note Multi-parenting is not supported; only the first match is returned.
# @param graph    [RDF::Graph] the graph to query
# @param resource [String]     URI of the child resource
# @return [String, nil] URI of the parent resource, or +nil+ if none found
def lookup_parent(graph:, resource:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?parent ?pred ?type WHERE
    { VALUES ?pred {dcat:service dcat:accessService dcat:catalog dcat:dataset dcat:distribution }
     ?parent a ?type .
     ?parent ?pred <#{resource}> .
    }
    ")
  result = query.execute(graph).first
  return nil unless result

  result[:parent].to_s
end

# Determines whether a +dcat:DataService+ is a catalog-level service or a
# distribution-level access service.  The distinction governs which LDP membership
# predicate is used in the injected +ldp:DirectContainer+.
#
# @param graph   [RDF::Graph] the graph to query
# @param service [String]     URI of the DataService resource
# @return [Array("DataService1", String)] if the parent is a Catalog
# @return [Array("DataService2", String)] if the parent is a Distribution/other
# @return [Array(nil, nil)]              if no parent can be found
def clarify_data_service_parent(graph:, service:)
  query = SPARQL.parse("
    #{NAMESPACES}
    SELECT DISTINCT ?parent ?pred ?type WHERE
    { VALUES ?pred {dcat:service dcat:accessService}
     ?parent a ?type .
     ?parent ?pred <#{service}> .
    }
    ")
  result = query.execute(graph).first
  return [nil, nil] unless result

  _pred  = result[:pred].to_s
  parent = result[:parent].to_s
  type   = result[:type].to_s

  return ["DataService1", parent] if type =~ /Catalog/

  ["DataService2", parent]
end

# Coerces +s+, +p+, +o+ into proper {RDF::URI} or {RDF::Literal} objects and
# inserts the resulting triple into +repo+.
#
# Object type inference (applied in order when no explicit +datatype+ is given):
# 1. Explicit +datatype+ supplied → typed literal
# 2. URI-shaped string            → {RDF::URI}
# 3. ISO 8601 datetime string     → +xsd:date+ literal
# 4. Float-shaped string          → +xsd:float+ literal
# 5. Integer-shaped string        → +xsd:int+ literal
# 6. Anything else                → plain string literal with language tag +:en+
#
# @param s        [String, RDF::URI]  subject
# @param p        [String, RDF::URI]  predicate
# @param o        [String, RDF::URI, Numeric] object
# @param repo     [RDF::Graph]        target graph
# @param datatype [RDF::URI, nil]     explicit XSD datatype for the object literal
# @return [true]
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
        elsif o.to_s =~ /^[+-]?\d+\.\d+/ && o.to_s !~ /[^+\-\d.]/
          RDF::Literal.new(o.to_s, datatype: RDF::XSD.float)
        elsif o.to_s =~ /^[+-]?[0-9]+$/ && o.to_s !~ /[^+\-\d.]/
          RDF::Literal.new(o.to_s, datatype: RDF::XSD.int)
        else
          RDF::Literal.new(o.to_s, language: :en)
        end
  end

  triple = RDF::Statement(s, p, o)
  repo.insert(triple)

  true
end

# @api private
def self.triplify_this(s, p, o, repo)
  triplify(s, p, o, repo)
end

# Returns all resources annotated with +vpConnection / VPDiscoverable+, together
# with their titles and optional contact and service-type metadata.
#
# @param graph [RDF::Graph] the graph to query
# @return [SPARQL::Client::Solutions] rows with +:s+, +:t+, +:title+, +:contact+, +:servicetype+
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

# Returns all VPDiscoverable resources whose title, description, or keyword
# contains +keyword+ (case-insensitive substring match).
#
# @param graph   [RDF::Graph] the graph to query
# @param keyword [String]     the search term
# @return [SPARQL::Client::Solutions] rows with +:s+, +:t+, +:title+, +:contact+
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
  graph.query(vpd)
end

# Returns all VPDiscoverable resources annotated with a +dcat:theme+ URI that
# contains +uri+ as a substring.
#
# @param graph [RDF::Graph] the graph to query
# @param uri   [String]     ontology URI (or fragment) to match against theme values
# @return [SPARQL::Client::Solutions] rows with +:s+, +:t+, +:title+, +:contact+
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

# Returns all unique +dcat:theme+ and +dcat:themeTaxonomy+ annotation URIs across
# the entire graph (not filtered to VPDiscoverable resources only).
#
# @param graph [RDF::Graph] the graph to query
# @return [SPARQL::Client::Solutions] rows with +:annot+
def verbose_annotations_query(graph:)
  vpd = SPARQL.parse("
      #{NAMESPACES}
      SELECT DISTINCT ?annot WHERE
      { VALUES ?annotation { dcat:theme dcat:themeTaxonomy }
        ?s  ?annotation ?annot .
        }")
  graph.query(vpd)
end

# Returns all unique +dc:keyword+ literals across the entire graph.
#
# @param graph [RDF::Graph] the graph to query
# @return [SPARQL::Client::Solutions] rows with +:kw+
def keyword_annotations_query(graph:)
  vpd = SPARQL.parse("
      #{NAMESPACES}
      select DISTINCT ?kw WHERE
      { VALUES ?searchfields { dc:keyword }
      ?s ?searchfields ?kw .
      }")
  graph.query(vpd)
end

# Returns all distinct +dc:type+ values on VPDiscoverable DataService resources.
# Useful for building a faceted list of available service types.
#
# @param graph [RDF::Graph] the graph to query
# @return [SPARQL::Client::Solutions] rows with +:type+
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
