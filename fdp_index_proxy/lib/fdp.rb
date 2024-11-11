
class FDP
  attr_accessor :graph, :dcat_address, :called, :toptype, :suffix

  DCATSTRUCTURE = { "Resource" => "http://www.w3.org/ns/dcat#resource",
                    "DataService1" => "http://www.w3.org/ns/dcat#service",
                    "Catalog" => "http://www.w3.org/ns/dcat#catalog",
                    "Dataset" => "http://www.w3.org/ns/ldp#dataset",
                    "Distribution" => "http://www.w3.org/ns/ldp#distribution",
                    "DataService2" => "http://www.w3.org/ns/ldp#accessService" }

  def initialize(address:)
    @graph = RDF::Graph.new
    @dcat_address = address  # address of this DCAT record
    @called = []  # has this address already been called?  List of known
    @toptype = nil  # will be dfdp, catalog, etc.
    warn "refreshing with toptype", toptype
    @args = URI(address).query
    load(address: @dcat_address)  # THIS IS A RECURSIVE FUNCTION using hydra pages
    # Now @graph has all of the triples for the resource

    iterate_dcat_record()  # this is also a recursive function - iterate over a FDP record or over a normal DCAT record
    warn "going into post process with", toptype
    post_process
    freezeme
  end

  def load(address:)
    return if called.include? address  # already known

    called << address
    unless address =~ /\?/
      address = "#{address}?#{@args}" if @args # try to add the previous query string to stay in the syntax, e.g. ?format=ttl
    end

    # address = "https://ostrails.github.io/sandbox/dataservice.ttl"
    warn "getting #{address}"
    begin
      r = RestClient::Request.execute(
        url: address,
        method: :get,
        verify_ssl: false,
        headers: { "Accept" => "application/ld+json, text/turtle, application/rdf+xml" }
      )
    rescue RestClient::ExceptionWithResponse => e 
      puts "An error occurred: #{e.response}" 
      return
    rescue RestClient::Exception, StandardError => e 
      puts "An error occurred: #{e}"
      return
    end
    return unless r&.respond_to? "body"  # abort if it isn't going to behave like a successful web call

    dcat = r.body

    # for testing
    # dcat = File.read("./sample.ttl")
    # warn "dcat", dcat

    # The rest of this routine will
    # 1. Load all of the RDF statements in @graph, other than hydra control statements
    # 2. detect dcat predicates and check that the object resolves - ignore triple if it doesn't 
    # 3. detect hydra nextPage and call THIS LOADING ROUTINE AGAIN if a next page is found
    #  None of the LDP logic is here.  All of that is in the post-Process function

    try = preparse(message: dcat)  # parse all statements that came from the initial call
    # try will be true if parse was successful, false if parse was unsuccessful, or a URL if it found another page
    # the only thing we care about right now is the new page, so return otherwise

    return if try.is_a?(TrueClass) || try.is_a?(FalseClass)

    return unless try=~/^http/  # found another page!
    warn "LOADING NEXT PAGE #{try}"
    load(address: try)
  end

  
  def preparse(message:)
    warn "format", RDF::Format.for({ sample: message.force_encoding("UTF-8") })
    return false if RDF::Format.for({ sample: message.force_encoding("UTF-8") }).to_s =~ /RDFa/

    readertype = RDF::Format.for({ sample: message.force_encoding("UTF-8") }).reader

    data = StringIO.new(message)
    nextpage = false

    readertype.new(data) do |reader|
      reader.each_statement do |statement|
        if ["http://www.w3.org/ns/dcat#dataset", 
          "http://www.w3.org/ns/dcat#distribution", 
          "http://www.w3.org/ns/dcat#service", 
          "http://www.w3.org/ns/dcat#accessService"].include?(statement.predicate.to_s)
            next unless testresolution(address: statement.object.to_s)  # filter 404s
        end
        # figure out why this isn't working...??
        # if ["<http://www.w3.org/ns/hydra/core#next>",
        #   "<http://www.w3.org/ns/hydra/core#nextPage>"].include?(statement.predicate.to_s)
        if statement.predicate.to_s =~ /nextPage/
          warn "FOUND ANOTHER PAGE #{statement.predicate.to_s} #{statement.object.to_s}"
            nextpage = statement.object.to_s.dup
            # Good lord... the IEPNB has HTML escaped the URLs that appear in their DCAT records.... 
            # why??  Please, I beg you, tell me WHY?!?!?!   ARRRRGHH
            # anyway, the string has lost its "&" in the argument list
            nextpage.gsub!(/page=/, "&page=")
            warn "FIXED PAGE TOOO #{nextpage}"
        end
        next if statement.predicate.to_s =~ /ns\/hydra/   # don't copy control statements
        next if statement.object.to_s =~ /ns\/hydra/   # don't copy control statements

        # Gobierno has a URL in a distribution (object) that looks like this: <https://doi:10.1016/j.scitotenv.2007.05.038>  :-(
        # so far, I can't find a URI parser that rejects it!  For now, catch it explicitly
        next if statement.object.to_s =~ /https?\:\/\/doi\:/

        # next unless apply_filters(statement: statement)
        @graph << statement
      end
    end
    # return nextpage if nextpage
    return true
  end


  def iterate_dcat_record
    toplevel = query_toplevel  # what is the top-level of the DCAT hierarchy from this latest call
    @toptype ||= toplevel  # don't reset if set - this contains the top level of the initial URL that started the cascade

    if toplevel == "FDP"
      parse_fdp  # this recursivelhy calls the load function
    else
      parse_dcat # this recursivelhy calls the load function
    end
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
    warn "toplevel results", types
    toptype = nil

    if types.include?("https://w3id.org/fdp/fdp-o#FAIRDataPoint")
      toptype = "FDP"
    elsif types.include?("http://www.w3.org/ns/dcat#Catalog")
      toptype = "Catalog"
    elsif types.include?("http://www.w3.org/ns/dcat#Dataset")
      toptype = "Dataset"
    elsif types.include?("http://www.w3.org/ns/dcat#Disgtribution")
      toptype = "Distribution"
    elsif types.include?("http://www.w3.org/ns/dcat#DataService")
      toptype = "DataService"
    end
    warn "final TOP type", toptype
    toptype
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

  # ====================================================== CACHE AND UTILITY

  def self.load_graph_from_cache(url:)
    address = Digest::SHA256.hexdigest url
    marshalled = "./cache/#{address}.marsh"
    begin
      warn "thawing file #{marshalled}"
      fdpstring = File.read(marshalled)
      fdp = Marshal.load(fdpstring)
    rescue StandardError => e
      warn "Error #{e.inspect}"
      return false
    end
    fdp.graph
  end

  def freezeme
    warn "freezing"
    # warn "GRAPH", @graph.dump(:turtle)
    File.open("/tmp/latestproxyoutput.ttl", 'w') { |file| file.write(@graph.dump(:turtle)) }
    # warn; warn; warn
    # return
    address = Digest::SHA256.hexdigest @dcat_address
    f = File.open("./cache/#{address}.marsh", "w")
    str = Marshal.dump(self).force_encoding("ASCII-8BIT")
    f.puts str
    f.close
  end

  def self.call_fdp_index(url: )
    # curl -v -X POST   https://fdps.ejprd.semlab-leiden.nl/   -H 'content-type: application/json'   -d '{"clientUrl": "https://w3id.org/duchenne-fdp"}'
    index = ENV["FDP_INDEX"]
    method = ENV["FDP_PROXY_METHOD"]
    method ||= "http" # default

    address = ENV["FDP_PROXY_HOST"].dup
    address.gsub!(/\/+$/, "") # remove trailing slashs
    address = method + "://" + address + "/fdp-index-proxy/proxy?url=#{url}"
    # example
    # https://index.bgv.cbgp.upm.es/fdp-index-proxy/proxy?url=https://my.dcat.site.org/test.dcat
    warn "calling FDP index at #{index} with  #{address}"
    begin
      r = RestClient::Request.execute(
        url: index,
        method: :post,
        verify_ssl: false,
        payload: { "clientUrl": address }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    rescue RestClient::ExceptionWithResponse => e 
      warn "An error occurred: #{e.response}" 
      return false
    rescue RestClient::Exception, StandardError => e 
      warn "An error occurred: #{e}"
      return false
    end
    true  
  end


  def testresolution(address:)
    warn "testing #{address}"
    begin
      r = RestClient::Request.execute(
        url: address,
        method: :get,
        verify_ssl: false,
        headers: { "Accept" => "application/ld+json, text/turtle, application/rdf+xml" }
        # headers: {"Accept" => "application/rdf+xml"}
      )
    rescue RestClient::ExceptionWithResponse => e 
      warn "An error occurred: #{e.response}" 
      return false
    rescue RestClient::Exception, StandardError => e 
      warn "An error occurred: #{e}"
      return false
    end
    true
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
