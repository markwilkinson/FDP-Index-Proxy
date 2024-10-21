require "./queries"

class FDP
  attr_accessor :graph, :topaddress, :called, :toptype, :suffix

  DCATSTRUCTURE = { "Resource" => "http://www.w3.org/ns/dcat#resource",
                    "DataService1" => "http://www.w3.org/ns/dcat#service",
                    "Catalog" => "http://www.w3.org/ns/dcat#catalog",
                    "Dataset" => "http://www.w3.org/ns/ldp#dataset",
                    "Distribution" => "http://www.w3.org/ns/ldp#distribution",
                    "DataService2" => "http://www.w3.org/ns/ldp#accessService" }

  def initialize(address:)
    @graph = RDF::Graph.new
    @topaddress = address  # address of this FDP
    @called = []  # has this address already been called?  List of known
    @toptype = nil  # will be dfdp, catalog, etc.
    warn "refreshing with toptype", toptype
    @suffix = address.gsub(/.*\?/, "")
    load(address: topaddress)  # THIS IS A RECURSIVE FUNCTION
    # Now @graph has all of the triples for the resource
    warn "going into post process with", toptype
    post_process
    freezeme
  end

  def load(address:)
    return if called.include? address  # already known

    called << address
    unless address =~ /\?/
      address = "#{address}?#{@suffix}"  # try to add the previous suffix to stay in the syntax
    end

    # address = address.gsub(%r{/$}, "")
    # address += "?format=ttl"

    # address = "https://ostrails.github.io/sandbox/dataservice.ttl"
    warn "getting #{address}"
    begin
      r = RestClient::Request.execute(
        url: address,
        method: :get,
        verify_ssl: false,
        headers: { "Accept" => "application/ld+json, text/turtle, application/rdf+xml" }
        # headers: {"Accept" => "application/rdf+xml"}
      )
    rescue StandardError => e
      warn "#{address} didn't resolve #{e.inspect}"
      # abort
    end
    return unless r
    return unless r.respond_to? "body"

    warn "CONTENT #{r.body}"

    dcat = r.body

    # for testing
    # dcat = File.read("./sample.ttl")
    # warn "dcat", dcat

    try = preparse(message: dcat)  # parse all statements that came from the initial call
    return unless try

    toplevel = query_toplevel  # what is the top-level of the DCAT hierarchy from this latest call
    @toptype ||= toplevel  # don't reset if set - this contains the top level of the initial URL that started the cascade

    if toplevel == "FDP"
      parse_fdp  # this recursivelhy calls the load function
    else
      parse_dcat # this recursivelhy calls the load function
    end
  end

  # This will only be called on the top-level DCAT object
  # which should either be an FDP, or a normal DCAT object type
  def preparse(message:)
    # warn "message", message
    warn "format", RDF::Format.for({ sample: message.force_encoding("UTF-8") })
    return false if RDF::Format.for({ sample: message.force_encoding("UTF-8") }).to_s =~ /RDFa/

    read = RDF::Format.for({ sample: message.force_encoding("UTF-8") }).reader

    data = StringIO.new(message)
    read.new(data) do |reader|
      reader.each_statement do |statement|
        @graph << statement
      end
    end
    true
  end

  def parse_fdp
    graph.each_statement do |s|
      if s.predicate.to_s == "http://www.w3.org/ns/ldp#contains"
        contained_thing = statement.object.to_s
        self.load(address: contained_thing) # this ends up being recursive... careful!
      end
    end
  end

  def parse_dcat
    # graph.each_statement do |s|
    #   if ["http://www.w3.org/ns/dcat#resource",
    #     "http://www.w3.org/ns/dcat#service",
    #     "http://www.w3.org/ns/dcat#catalog",
    #     "http://www.w3.org/ns/dcat#dataset",
    #     "http://www.w3.org/ns/dcat#distribution",
    #     "http://www.w3.org/ns/dcat#accessService"].include? s.predicate.to_s
    #     contained_thing = s.object.to_s
    #     # warn "calling load again with toptype ", @toptype
    #     self.load(address: contained_thing) # this can be recursive... careful!
    #   end
    # end
  end

  def query_toplevel
    # the logic here is to find the "highest level" DCAT object
    # e.g. Catalog is higher than Dataset
    query = SPARQL.parse("SELECT distinct ?type WHERE { ?s a ?type }")  # this is called for every objecgt type in the DCAT record
    types = query.execute(@graph).map { |result| result[:type].to_s }
    # warn "toplevel results", types
    if types.include?("https://w3id.org/fdp/fdp-o#FAIRDataPoint")
      "FDP"
    elsif types.include?("http://www.w3.org/ns/dcat#Catalog")
      "Catalog"
    elsif types.include?("http://www.w3.org/ns/dcat#Dataset")
      "Dataset"
    elsif types.include?("http://www.w3.org/ns/dcat#Disgtribution")
      "Distribution"
    elsif types.include?("http://www.w3.org/ns/dcat#DataService")
      "DataService"
    end
    # warn "final type", thistype
  end

  # add the other FDP required stuff via SPARQL and <<statement
  def post_process
    # warn "\n\ncurrent type is", @toptype
    return if @toptype == "FDP"

    subjects = find_subject_uri_query(graph: @graph, type: @toptype)  # type is FDP, Catalog, Dataset, etc. - the highest level of the DCAT hierarchy that was found
    # warn "found subjects", subjects
    _fdp_uri = inject_FDP_root(subject: subjects.first.to_s)  # it doesn't matter which one, because they're all the same tupe (should only be one anyway!)

    dcat_class_subjects = find_dcat_classes(graph: @graph) # returns [[?s ?type], [?s ?type]...]
    # warn "\n\n\n\dcat class subjects", dcat_class_subjects
    dcat_class_subjects.each do |s, type|
      # warn "class type for  container is ", type
      next if type == "https://w3id.org/fdp/fdp-o#FAIRDataPoint"

      inject_class_container(subject: s, type: type)
      inject_title(subject: s, type: type)
      inject_contact(subject: s, type: type)
    end
  end

  def inject_title(subject:, type:)
    objecttype = type.dup.gsub!(%r{^.*[#/]}, "")  # take just suffix

    title = lookup_title(graph: @graph, resource: subject)
    return if title

    title = "#{objecttype} from #{subject}"
    triplify(subject, "http://purl.org/dc/terms/title", title, @graph)
  end

  def inject_contact(subject:, type:)
    uuid = SecureRandom.uuid #=> "1ca71cd6-08c4-4855-9381-2f41aeffe59c"
    type.dup.gsub!(%r{^.*[#/]}, "")  # take just suffix

    contactresults = lookup_contact(graph: @graph, resource: subject) # SELECT DISTINCT  ?contact ?url ?email ?name WHERE
    contact, url = process_contact_results(results: contactresults)
    return if contact && url  # everythign is fine - already there

    lookup_publisher(graph: @graph, resource: subject) # SELECT DISTINCT ?pred ?contact WHERE
    publisher = process_publisher_results(results: contactresults)
    publisher ||= url  # publisher is deafult, fllowed by email, followed by nothing

    if contact  # we already have a contact node
      if publisher
        triplify(contact, "http://www.w3.org/2006/vcard/ns#url", publisher, @graph)
      elsif url
        triplify(contact, "http://www.w3.org/2006/vcard/ns#url", url, @graph)
      end
    elsif publisher  # if there isn't a contact node
      triplify(subject, "http://www.w3.org/ns/dcat#contactPoint", "http://flair.gg.fakenode/contactPoint/#{uuid}",
               @graph)
      triplify("http://flair.gg.fakenode/contactPoint/#{uuid}", "http://www.w3.org/2006/vcard/ns#url", publisher, @graph)
    else  # there's nada!  So just use the URL of the subject itself
      triplify(subject, "http://www.w3.org/ns/dcat#contactPoint", "http://flair.gg.fakenode/contactPoint/#{uuid}",
               @graph)
      triplify("http://flair.gg.fakenode/contactPoint/#{uuid}", "http://www.w3.org/2006/vcard/ns#url", subject, @graph)
    end
  end

  def process_contact_results(results:)
    # SELECT DISTINCT  ?contact ?url ?email ?name WHERE
    url = nil
    contact = nil
    results.each do |res|
      next unless res[:contact]  # need a contact URL to inject safely

      contact = res[:contact]
      url = res[:url] if res[:url]
      next if url

      url = res[:email] if res[:email]
    end
    [contact, url]
  end

  def process_publisher_results(results:)
    # SELECT DISTINCT ?pred ?contact WHERE
    contact = nil
    results.each do |res|
      next unless res[:contact]  # need a contact URL to inject safely

      contact = res[:contact]
    end
    contact
  end

  def inject_class_container(subject:, type:)
    objecttype = type.dup.gsub!(%r{^.*[#/]}, "")  # take just suffix
    # warn "Inject class container #{subject} #{objecttype}"
    parent = lookup_parent(graph: @graph, resource: subject)
    return unless parent

    if objecttype == "DataService"
      warn "getting parent for #{subject}"
      objecttype, parent = clarify_data_service_parent(graph: @graph, service: subject) # returns DataService1 if it is a catalog service, DataService2 if it is a disgtribution service
      objecttype ||= "DataService1"
      # warn "DataService #{objecttype} #{parent}"
    end
    return unless objecttype  # the clarification of parent can return nil

    predicate = DCATSTRUCTURE[objecttype]  # defined in the top of the page  "DataService1" =>  "http://www.w3.org/ns/dcat#service",
    unless predicate
      warn "container predicate not fopund in hash... moving on!"
      return
    end

    triplify("#{subject}#container", RDF.type, "http://www.w3.org/ns/ldp#DirectContainer", @graph)
    unless subject&.empty?
      triplify("#{subject}#container", "http://www.w3.org/ns/ldp#membershipResource", parent,
               @graph)
    end
    unless predicate&.empty?
      triplify("#{subject}#container", "http://www.w3.org/ns/ldp#hasMemberRelation", predicate,
               @graph)
    end
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#contains", subject, @graph) unless subject&.empty?
    triplify(subject, "https://w3id.org/ejp-rd/vocabulary#vpConnection",
             "https://w3id.org/ejp-rd/vocabulary#VPDiscoverable", @graph)
  end

  def inject_FDP_root(subject:)
    # @prefix ldp: <http://www.w3.org/ns/ldp#> .
    # @prefix dcterms: <http://purl.org/dc/terms/> .
    # @prefix bt: <http://example.org/vocab/bugtracker#> .

    # <catalog#container> a ldp:DirectContainer;
    #   ldp:membershipResource <catalog>;
    #   ldp:hasMemberRelation bt:dataset;
    #   dcterms:title "Product description of the LDP Demo product which is also an LDP-DC";
    #   ldp:contains <dataset1>, <dataset2> .

    # <catalog> a dcat:Catalog;
    #   dcterms:title "LDP Demo";
    #   dcat:dataset <dataset1>, <dataset2> .

    return if subject&.empty?

    fdp = "#{subject}#fdp"

    triplify("#{subject}#container", RDF.type, "http://www.w3.org/ns/ldp#DirectContainer", @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#membershipResource", fdp, @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#hasMemberRelation", "http://www.w3.org/ns/ldp#contains",
             @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#contains", subject, @graph)

    triplify(fdp, RDF.type, "https://w3id.org/fdp/fdp-o#FAIRDataPoint", @graph)
    triplify(fdp, RDF.type, "https://w3id.org/fdp/fdp-o#MetadataService", @graph)
    triplify(fdp, RDF.type, "http://www.w3.org/ns/dcat#Resource", @graph)
    triplify(fdp, "http://purl.org/dc/terms/title", "Imported DCAT from #{subject}", @graph)
    triplify(fdp, "http://www.w3.org/ns/ldp#contains", "#{subject}", @graph)
    triplify(fdp, "https://w3id.org/ejp-rd/vocabulary#vpConnection",
             "https://w3id.org/ejp-rd/vocabulary#VPDiscoverable", @graph)
    fdp
  end

  # ====================================================== CACHE

  def self.load_from_cache(marshalled:)
    begin
      warn "thawing file #{marshalled}"
      fdpstring = File.read(marshalled)
      fdp = Marshal.load(fdpstring)
    rescue StandardError => e
      warn "Error #{e.inspect}"
    end
    fdp
  end

  def freezeme
    warn "freezing"
    warn "GRAPH", @graph.dump(:turtle)
    warn; warn; warn
    return
    address = Digest::SHA256.hexdigest @topaddress
    f = File.open("./cache/#{address}.marsh", "w")
    str = Marshal.dump(self).force_encoding("ASCII-8BIT")
    f.puts str
    f.close
  end

  # I don't think this is used anymore
  # def parse(message:)
  #   data = StringIO.new(message)
  #   RDF::Reader.for(:turtle).new(data) do |reader|
  #     reader.each_statement do |statement|
  #       @graph << statement
  #       if statement.predicate.to_s == "http://www.w3.org/ns/ldp#contains"
  #         contained_thing = statement.object.to_s
  #         self.load(address: contained_thing) # this ends up being recursive... careful!
  #       end
  #     end
  #   end
  # end
end
