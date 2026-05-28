require "digest"
require "fileutils"

# Fetches a remote DCAT record, enriches it with FDP-required triples, and
# stores the resulting {RDF::Graph} in an in-process cache for fast serving.
#
# == Processing pipeline
#
# Instantiating this class drives the full pipeline synchronously:
#
# 1. {#load} fetches the source URL via HTTP, following +hydra:nextPage+
#    pagination, accumulating all statements into {#graph} via {#preparse}.
# 2. {#iterate_dcat_record} inspects {#graph} to determine whether the resource
#    is an FDP-native record ({#parse_fdp}) or a plain DCAT record ({#parse_dcat}).
# 3. {#post_process} injects the triples required by the FDP specification:
#    - an +fdp-o:FAIRDataPoint+ root node ({#inject_FDP_root})
#    - LDP +DirectContainer+ nodes linking each DCAT resource to its parent
#      ({#inject_class_container})
#    - +ejp-rd:vpConnection / VPDiscoverable+ annotations on every resource,
#      making them discoverable in the Virtual Platform network
#    - fallback +dc:title+ and +dcat:contactPoint+ where missing
# 4. {#cache_store} writes the enriched graph to the in-process +@@cache+ hash
#    and persists the source URL to the on-disk registry.
#
# == In-process cache
#
# +@@cache+ is a plain +Hash+ keyed by the SHA-256 digest of the source URL.
# Because the Sinatra/WEBrick process is single-process, this hash persists
# across requests with zero serialisation overhead — critical for graphs that
# can contain hundreds of thousands of triples.  The TTL is controlled by
# {CACHE_TTL} and defaults to 24 hours.
#
# @attr_accessor graph   [RDF::Graph]    the enriched RDF graph for this record
# @attr_accessor address [String]        the original source DCAT URL
# @attr_accessor called  [Array<String>] URLs already fetched in this build (loop guard)
# @attr_accessor toptype [String, nil]   highest DCAT class found:
#   +"FDP"+, +"Catalog"+, +"Dataset"+, +"Distribution"+, or +"DataService"+
class FDP
  attr_accessor :graph, :address, :called, :toptype, :suffix

  # @!visibility private
  @@cache = {}         # { sha256 => { graph: RDF::Graph, cached_at: Time } }
  # @!visibility private
  @@url_registry = [] # original DCAT URLs; persisted to REGISTRY_PATH for ping

  # Path to the JSON file that lists all registered source URLs.
  # Read by {.ping} to rebuild the in-process cache after a process restart.
  REGISTRY_PATH = "./cache/registry.json"

  # Cache time-to-live in seconds.  Configurable via the +FDP_CACHE_TTL+
  # environment variable; defaults to +86_400+ (24 hours).
  CACHE_TTL = (ENV.fetch("FDP_CACHE_TTL", 86_400)).to_i

  # Maps the DCAT class names returned by {#query_toplevel} to the LDP predicate
  # used when building an +ldp:DirectContainer+ for that class.
  # "DataService1" is a DataService that is a child of a Catalog;
  # "DataService2" is a DataService that is an access service on a Distribution.
  DCATSTRUCTURE = {
    "Resource"     => "http://www.w3.org/ns/dcat#resource",
    "DataService1" => "http://www.w3.org/ns/dcat#service",
    "Catalog"      => "http://www.w3.org/ns/dcat#catalog",
    "Dataset"      => "http://www.w3.org/ns/ldp#dataset",
    "Distribution" => "http://www.w3.org/ns/ldp#distribution",
    "DataService2" => "http://www.w3.org/ns/ldp#accessService"
  }.freeze

  # Builds a fully enriched FDP graph for +address+ and stores it in cache.
  # This is the sole entry point; all pipeline steps are driven from here.
  #
  # @param address [String] URL of the source DCAT record to proxy
  def initialize(address:)
    @graph   = RDF::Graph.new
    @address = address
    @called  = []    # guards against circular references when following links
    @toptype = nil   # resolved by the first call to iterate_dcat_record

    warn "refreshing with toptype", toptype
    @args = URI(address).query  # preserve any query string (e.g. ?format=ttl)

    load(address: @address)  # step 1 — fetch all RDF, following pagination
    iterate_dcat_record      # step 2 — determine resource type, traverse hierarchy
    warn "going into post process with", toptype
    post_process             # step 3 — inject FDP-required triples
    cache_store              # step 4 — store enriched graph in memory
  end

  # Fetches +address+ via HTTP and merges its statements into {#graph}.
  # Follows +hydra:nextPage+ pagination by calling itself recursively.
  # Skips any URL already in {#called} to prevent infinite loops.
  #
  # @param address [String] URL to fetch
  # @return [void]
  def load(address:)
    return if called.include? address

    called << address

    # Re-attach the original query string so servers that require e.g. ?format=ttl
    # continue to return RDF rather than an HTML landing page.
    if !(address =~ /\?/) && @args
      address = "#{address}?#{@args}"
    end

    warn "getting #{address}"
    begin
      r = RestClient::Request.execute(
        url: address,
        method: :get,
        verify_ssl: false,
        timeout: 30,
        open_timeout: 10,
        headers: { "Accept" => "application/ld+json, text/turtle, application/rdf+xml" }
      )
    rescue RestClient::ExceptionWithResponse => e
      puts "An error occurred: #{e.response}"
      return
    rescue RestClient::Exception, StandardError => e
      puts "An error occurred: #{e}"
      return
    end

    return unless r&.respond_to? "body"

    dcat = r.body
    warn "dcat", dcat

    # preparse returns true (done), false (format skipped), or a URL (next page).
    # Only the URL case requires further action.
    try = preparse(message: dcat)
    warn "Try is #{try}"
    warn "Graph is is #{@graph} #{@graph.size}"

    return if try.is_a?(TrueClass) || try.is_a?(FalseClass)
    return unless try =~ /^http/

    warn "LOADING NEXT PAGE #{try}"
    load(address: try)
  end

  # Parses the raw RDF body and appends valid statements to {#graph}.
  # Applies three filtering rules before storing any statement:
  #
  # 1. Skips the body entirely if detected as RDFa (HTML), to avoid ingesting
  #    page-chrome triples unrelated to the dataset.
  # 2. Drops DCAT structural predicates (dataset, distribution, etc.) whose
  #    object URL does not resolve — prevents broken links propagating into graph.
  # 3. Strips all +hydra+ control triples from the stored graph while still
  #    returning the +nextPage+ URL to the caller so pagination can continue.
  #
  # @param message [String] raw HTTP response body (RDF in any supported format)
  # @return [String]  the next hydra page URL, if one was found
  # @return [Boolean] +true+ if parsing completed normally; +false+ on format error
  def preparse(message:)
    warn "format", RDF::Format.for({ sample: message.force_encoding("UTF-8") })
    return false if RDF::Format.for({ sample: message.force_encoding("UTF-8") }).to_s =~ /RDFa/

    readertype = RDF::Format.for({ sample: message.force_encoding("UTF-8") }).reader

    data     = StringIO.new(message)
    nextpage = false

    readertype.new(data) do |reader|
      reader.each_statement do |statement|
        # Filter out DCAT structural links to resources that return 404 or
        # non-RDF.  Real-world DCAT records frequently contain broken URLs.
        if ["http://www.w3.org/ns/dcat#dataset",
            "http://www.w3.org/ns/dcat#distribution",
            "http://www.w3.org/ns/dcat#service",
            "http://www.w3.org/ns/dcat#accessService"].include?(statement.predicate.to_s) &&
           !testresolution(address: statement.object.to_s)
          next
        end

        if statement.predicate.to_s =~ /nextPage/
          warn "FOUND ANOTHER PAGE #{statement.predicate} #{statement.object}"
          nextpage = statement.object.to_s.dup
          # Some publishers HTML-escape URLs inside their RDF, losing the "&"
          # separator between query parameters.  Restore it here.
          nextpage.gsub!("page=", "&page=")
          warn "FIXED PAGE TOOO #{nextpage}"
        end

        # Discard hydra control triples — they describe the pagination mechanism,
        # not the dataset itself, and must not appear in the enriched graph.
        next if statement.predicate.to_s =~ %r{ns/hydra}
        next if statement.object.to_s    =~ %r{ns/hydra}

        # Guard against malformed DOI URIs used as HTTP URIs (e.g. https://doi:10.x).
        # No Ruby URI parser currently rejects these, so we catch them explicitly.
        next if statement.object.to_s =~ %r{https?://doi:}

        @graph << statement
      end
    end

    nextpage || true
  end

  # Determines the type of the top-level resource and delegates traversal.
  # Sets {#toptype} on the first call only, so recursive calls during FDP
  # traversal do not overwrite the original root type.
  #
  # @return [void]
  def iterate_dcat_record
    toplevel  = query_toplevel
    @toptype ||= toplevel   # preserve root type across recursive calls

    if toplevel == "FDP"
      parse_fdp   # FDP-native: follow ldp:contains links
    else
      parse_dcat  # plain DCAT: currently inactive (see method doc)
    end
  end

  # Traverses an FDP-native record by following +ldp:contains+ links and loading
  # each contained resource into {#graph}.
  #
  # @note Only reached when the source URL is itself an FDP endpoint
  #   (type +fdp-o:FAIRDataPoint+).  Plain DCAT records go through {#parse_dcat}.
  # @return [void]
  def parse_fdp
    graph.each_statement do |s|
      if s.predicate.to_s == "http://www.w3.org/ns/ldp#contains"
        contained_thing = s.object.to_s
        load(address: contained_thing)
      end
    end
  end

  # Traverses a plain DCAT record by following structural predicates.
  #
  # @note Currently intentionally inactive.  In practice too many publishers link
  #   to HTML pages rather than RDF distributions, making reliable recursive
  #   traversal impossible.  Retained as a placeholder for future re-enablement.
  # @return [void]
  def parse_dcat
    # Intentionally empty — see note above.
  end

  # Inspects all +rdf:type+ statements in {#graph} and returns the highest-level
  # DCAT class present, in descending priority order:
  # FDP > Catalog > Dataset > Distribution > DataService.
  #
  # @return [String, nil] one of +"FDP"+, +"Catalog"+, +"Dataset"+,
  #   +"Distribution"+, +"DataService"+, or +nil+ if no known type is found
  def query_toplevel
    types = []
    @graph.each_statement do |statement|
      types << statement.object.to_s if statement.predicate == RDF.type
    end
    types.uniq!

    warn "toplevel results", types

    toptype = nil
    if types.include?("https://w3id.org/fdp/fdp-o#FAIRDataPoint")
      toptype = "FDP"
    elsif types.include?("http://www.w3.org/ns/dcat#Catalog")
      toptype = "Catalog"
    elsif types.include?("http://www.w3.org/ns/dcat#Dataset")
      toptype = "Dataset"
    elsif types.include?("http://www.w3.org/ns/dcat#Distribution")
      toptype = "Distribution"
    elsif types.include?("http://www.w3.org/ns/dcat#DataService")
      toptype = "DataService"
    end

    warn "final TOP type", toptype
    warn "No rdf:type triples found — likely non-RDF response or parsing skipped" if types.empty?

    toptype
  end

  # Injects all FDP-required triples that are absent from plain DCAT records.
  # Called once after the full RDF graph has been loaded and traversed.
  # Skips processing if the source is already an FDP-native endpoint.
  #
  # @return [void]
  def post_process
    return if @toptype == "FDP"

    # Build the synthetic FAIRDataPoint root above the top-level DCAT resource.
    subjects = find_subject_uri_query(graph: @graph, type: @toptype)
    inject_FDP_root(subject: subjects.first.to_s)

    # For every DCAT resource, add the LDP container structure and ensure that
    # the mandatory dc:title and dcat:contactPoint metadata is present.
    dcat_class_subjects = find_dcat_classes(graph: @graph)
    dcat_class_subjects.each do |s, type|
      next if type == "https://w3id.org/fdp/fdp-o#FAIRDataPoint"

      inject_class_container(subject: s, type: type)
      inject_title(subject: s, type: type)
      inject_contact(subject: s, type: type)
    end
  end

  # Ensures the resource has a +dc:title+.
  # If none is present in {#graph}, synthesises one from the resource type and URI.
  #
  # @param subject [String] URI of the DCAT resource
  # @param type    [String] full URI of the resource's RDF type
  # @return [void]
  def inject_title(subject:, type:)
    objecttype = type.dup.gsub!(%r{^.*[#/]}, "")
    title = lookup_title(graph: @graph, resource: subject)
    return if title

    title = "#{objecttype} from #{subject}"
    triplify(subject, "http://purl.org/dc/terms/title", title, @graph)
  end

  # Ensures the resource has a +dcat:contactPoint+ with a resolvable URL.
  # Falls back through several strategies in order:
  #
  # 1. Existing contact node with a URL — nothing to do, return early.
  # 2. Existing contact node without a URL — attach +dc:publisher+ or email URL.
  # 3. No contact node but a publisher URL exists — create a synthetic node.
  # 4. Nothing available — use the resource URI itself as the contact URL.
  #
  # Synthetic nodes are minted under +http://flair.gg.fakenode/contactPoint/+
  # with a random UUID to avoid URI collisions across records.
  #
  # @param subject [String] URI of the DCAT resource
  # @param type    [String] full URI of the resource's RDF type
  # @return [void]
  def inject_contact(subject:, type:)
    uuid = SecureRandom.uuid
    type.dup.gsub!(%r{^.*[#/]}, "")

    contactresults = lookup_contact(graph: @graph, resource: subject)
    contact, url   = process_contact_results(results: contactresults)
    return if contact && url  # already complete — nothing to inject

    lookup_publisher(graph: @graph, resource: subject)
    publisher = process_publisher_results(results: contactresults)
    publisher ||= url

    if contact
      # A contact node exists but lacks a URL — attach the best available URL.
      if publisher
        triplify(contact, "http://www.w3.org/2006/vcard/ns#url", publisher, @graph)
      elsif url
        triplify(contact, "http://www.w3.org/2006/vcard/ns#url", url, @graph)
      end
    elsif publisher
      # No contact node yet — create one and wire in the publisher URL.
      triplify(subject, "http://www.w3.org/ns/dcat#contactPoint",
               "http://flair.gg.fakenode/contactPoint/#{uuid}", @graph)
      triplify("http://flair.gg.fakenode/contactPoint/#{uuid}",
               "http://www.w3.org/2006/vcard/ns#url", publisher, @graph)
    else
      # Last resort: use the resource URI itself so the FDP Index always has
      # something resolvable to dereference as a contact.
      triplify(subject, "http://www.w3.org/ns/dcat#contactPoint",
               "http://flair.gg.fakenode/contactPoint/#{uuid}", @graph)
      triplify("http://flair.gg.fakenode/contactPoint/#{uuid}",
               "http://www.w3.org/2006/vcard/ns#url", subject, @graph)
    end
  end

  # Extracts the contact node URI and a resolvable URL from SPARQL contact results.
  # Prefers +vcard:url+ over +vcard:hasEmail+ when both are present.
  #
  # @param results [SPARQL::Client::Solutions] rows with :contact, :url, :email, :name
  # @return [Array(RDF::Term, RDF::Term)] +[contact_node, url]+ (either may be +nil+)
  def process_contact_results(results:)
    url     = nil
    contact = nil
    results.each do |res|
      next unless res[:contact]

      contact = res[:contact]
      url     = res[:url]   if res[:url]
      next if url
      url     = res[:email] if res[:email]
    end
    [contact, url]
  end

  # Extracts the publisher URI from SPARQL publisher results.
  #
  # @param results [SPARQL::Client::Solutions] rows with :pred and :contact
  # @return [RDF::Term, nil] the publisher URI, or +nil+ if absent
  def process_publisher_results(results:)
    contact = nil
    results.each do |res|
      next unless res[:contact]
      contact = res[:contact]
    end
    contact
  end

  # Injects an +ldp:DirectContainer+ node linking a DCAT resource back to its
  # parent, satisfying the LDP navigation requirement of the FDP specification.
  # Also marks the resource as +ejp-rd:VPDiscoverable+ so it appears in
  # Virtual Platform discovery queries.
  #
  # The container URI is minted as +<subject>#container+ and declares:
  # - +ldp:membershipResource+ → parent URI
  # - +ldp:hasMemberRelation+  → the DCAT predicate from {DCATSTRUCTURE}
  # - +ldp:contains+           → the resource URI itself
  #
  # @param subject [String] URI of the DCAT resource
  # @param type    [String] full URI of the resource's RDF type
  # @return [void]
  def inject_class_container(subject:, type:)
    objecttype = type.dup.gsub!(%r{^.*[#/]}, "")
    parent     = lookup_parent(graph: @graph, resource: subject)
    return unless parent

    if objecttype == "DataService"
      # A DataService can sit under a Catalog or under a Distribution.
      # The distinction determines which LDP membership predicate is correct.
      objecttype, parent = clarify_data_service_parent(graph: @graph, service: subject)
      objecttype ||= "DataService1"
    end
    return unless objecttype

    predicate = DCATSTRUCTURE[objecttype]
    unless predicate
      warn "container predicate not found in hash... moving on!"
      return
    end

    triplify("#{subject}#container", RDF.type,
             "http://www.w3.org/ns/ldp#DirectContainer", @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#membershipResource",
             parent, @graph) unless subject&.empty?
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#hasMemberRelation",
             predicate, @graph) unless predicate&.empty?
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#contains",
             subject, @graph) unless subject&.empty?

    # Mark as VPDiscoverable so discovery clients can find this resource.
    triplify(subject, "https://w3id.org/ejp-rd/vocabulary#vpConnection",
             "https://w3id.org/ejp-rd/vocabulary#VPDiscoverable", @graph)
  end

  # Injects the +fdp-o:FAIRDataPoint+ root node and its mandatory metadata above
  # the top-level DCAT resource.  The FDP specification requires this node at the
  # apex of the LDP hierarchy.
  #
  # The synthetic FDP node is minted as +<subject>#fdp+ and declares:
  # - +rdf:type fdp-o:FAIRDataPoint+ and +fdp-o:MetadataService+
  # - +ldp:contains+ → the top-level DCAT resource
  # - An anonymous publisher agent (+urn:anonymous:forfdpcompliance+)
  # - +ejp-rd:vpConnection / VPDiscoverable+ so the FDP itself is discoverable
  #
  # @param subject [String] URI of the top-level DCAT resource (Catalog, Dataset…)
  # @return [String] URI of the new FDP root node (+<subject>#fdp+)
  # @return [nil]    if +subject+ is blank
  def inject_FDP_root(subject:)
    return if subject&.empty?

    # Mark the top-level DCAT resource as VPDiscoverable in its own right,
    # so discovery clients reach it directly without going via the FDP root.
    triplify(subject, "https://w3id.org/ejp-rd/vocabulary#vpConnection",
             "https://w3id.org/ejp-rd/vocabulary#VPDiscoverable", @graph)

    fdp = "#{subject}#fdp"

    # Wire the container: FDP root → contains → top-level DCAT resource
    triplify("#{subject}#container", RDF.type,
             "http://www.w3.org/ns/ldp#DirectContainer", @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#membershipResource",
             fdp, @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#hasMemberRelation",
             "http://www.w3.org/ns/ldp#contains", @graph)
    triplify("#{subject}#container", "http://www.w3.org/ns/ldp#contains",
             subject, @graph)

    # Declare the FDP root node and its mandatory metadata.
    triplify(fdp, RDF.type, "https://w3id.org/fdp/fdp-o#FAIRDataPoint", @graph)
    triplify(fdp, RDF.type, "https://w3id.org/fdp/fdp-o#MetadataService", @graph)
    triplify(fdp, RDF.type, "http://www.w3.org/ns/dcat#Resource", @graph)
    triplify(fdp, "http://purl.org/dc/terms/title",
             "Imported DCAT from #{subject}", @graph)
    triplify(fdp, "http://www.w3.org/ns/ldp#contains", subject.to_s, @graph)
    triplify(fdp, "https://w3id.org/ejp-rd/vocabulary#vpConnection",
             "https://w3id.org/ejp-rd/vocabulary#VPDiscoverable", @graph)
    triplify(fdp, "http://purl.org/dc/terms/language",
             "http://id.loc.gov/vocabulary/iso639-1/en", @graph)
    triplify(fdp, "http://purl.org/dc/terms/publisher",
             "urn:anonymous:forfdpcompliance", @graph)
    triplify(fdp, "http://www.w3.org/ns/dcat#landingPage", fdp, @graph)
    triplify(fdp, "http://www.w3.org/ns/dcat#keyword", "fair data point", @graph)

    # Minimal anonymous publisher node required for FDP compliance.
    triplify("urn:anonymous:forfdpcompliance", RDF.type,
             "http://xmlns.com/foaf/0.1/Agent", @graph)
    triplify("urn:anonymous:forfdpcompliance", "http://xmlns.com/foaf/0.1/name",
             "anonymous", @graph)

    fdp
  end

  # ====================================================== CACHE AND UTILITY

  # Stores the enriched {#graph} in the in-process cache, registers {#address}
  # in the persistent URL registry, and writes a debug Turtle dump to
  # +/tmp/latestproxyoutput.ttl+ for inspection during development.
  #
  # @return [void]
  def cache_store
    key = Digest::SHA256.hexdigest(@address)
    @@cache[key] = { graph: @graph, cached_at: Time.now }
    self.class.register_url(@address)
    File.write("/tmp/latestproxyoutput.ttl", @graph.dump(:turtle))
    warn "Cached graph for #{@address} (#{@graph.size} triples)"
  end

  # Retrieves a cached {RDF::Graph} for the given source URL, or returns +false+
  # if the entry is absent or has exceeded {CACHE_TTL}.
  #
  # @param url [String] the original source DCAT URL
  # @return [RDF::Graph] the cached graph, if present and within TTL
  # @return [false]      on cache miss or expiry
  def self.load_graph_from_cache(url:)
    key   = Digest::SHA256.hexdigest(url)
    entry = @@cache[key]
    unless entry
      warn "CACHE MISS for #{url}"
      return false
    end

    age = Time.now - entry[:cached_at]
    if age > CACHE_TTL
      warn "CACHE EXPIRED for #{url} (age: #{age.to_i}s)"
      @@cache.delete(key)
      return false
    end

    warn "CACHE HIT for #{url} (age: #{age.to_i}s)"
    entry[:graph]
  end

  # Adds +url+ to the in-process registry and persists the full list to
  # {REGISTRY_PATH} as a JSON array.  No-ops if the URL is already registered.
  #
  # @param url [String] source DCAT URL to register
  # @return [void]
  def self.register_url(url)
    return if @@url_registry.include?(url)

    @@url_registry << url
    FileUtils.mkdir_p("./cache")
    File.write(REGISTRY_PATH, @@url_registry.to_json)
  end

  # Re-fetches, re-enriches, and re-registers every URL in the registry with the
  # FDP Index.  Intended to be triggered weekly by an external cron so that the
  # Index always holds up-to-date metadata.
  #
  # On a cold start (empty +@@url_registry+), reads {REGISTRY_PATH} from disk
  # before processing begins, so the ping survives process restarts.  Errors for
  # individual URLs are caught and logged; the remaining URLs are still processed.
  #
  # @return [void]
  def self.ping
    # Re-hydrate from disk when the in-process list is empty (e.g. after restart).
    if @@url_registry.empty? && File.exist?(REGISTRY_PATH)
      begin
        @@url_registry = JSON.parse(File.read(REGISTRY_PATH))
        warn "Loaded #{@@url_registry.size} URLs from registry"
      rescue JSON::ParserError => e
        warn "Could not parse URL registry: #{e.message}"
        @@url_registry = []
      end
    end

    @@url_registry.each do |url|
      @@cache.delete(Digest::SHA256.hexdigest(url))  # evict so a fresh graph is built
      begin
        FDP.new(address: url)
        FDP.call_fdp_index(address: url)
      rescue StandardError => e
        warn "Error refreshing #{url}: #{e.message}"
      end
    end
  end

  # POSTs the proxy URL for +address+ to the configured FDP Index, telling the
  # Index to dereference this proxy when it wants the enriched graph.
  #
  # The proxy URL takes the form:
  #   <FDP_PROXY_METHOD>://<FDP_PROXY_HOST>/fdp-index-proxy/proxy?url=<address>
  #
  # Required environment variables: +FDP_INDEX+, +FDP_PROXY_HOST+,
  # +FDP_PROXY_METHOD+.
  #
  # @param address [String] original source DCAT URL
  # @return [true]  on success
  # @return [false] on any HTTP or network error
  def self.call_fdp_index(address:)
    index  = ENV.fetch("FDP_INDEX", nil)
    method = ENV.fetch("FDP_PROXY_METHOD", "http")

    proxyhost = ENV["FDP_PROXY_HOST"].dup
    proxyhost.gsub!(%r{/+$}, "")  # strip any trailing slashes
    proxied_address = "#{method}://#{proxyhost}/fdp-index-proxy/proxy?url=#{address}"

    warn "calling FDP index at #{index} with #{proxied_address}"
    begin
      RestClient::Request.execute(
        url: index,
        method: :post,
        verify_ssl: false,
        timeout: 30,
        open_timeout: 10,
        payload: { clientUrl: proxied_address }.to_json,
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

  # Tests whether +address+ resolves to an RDF response.
  # Used by {#preparse} to filter out dead DCAT structural links before they are
  # written into {#graph}.
  #
  # @param address [String] URL to probe
  # @return [true]  if the HTTP request succeeds
  # @return [false] on any HTTP or network error
  def testresolution(address:)
    warn "testing #{address}"
    begin
      RestClient::Request.execute(
        url: address,
        method: :get,
        verify_ssl: false,
        timeout: 30,
        open_timeout: 10,
        headers: { "Accept" => "application/ld+json, text/turtle, application/rdf+xml" }
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
end
