# frozen_string_literal: false

require_relative "../../lib/fdp_index_proxy"
require_relative "../../lib/fdp"

# Defines all HTTP routes for the FDP Index Proxy and configures the Sinatra
# server.  Called once from {FdpIndexProxy::Main} via +set_routes+.
#
# == Route overview
#
#   GET  /fdp-index-proxy                → OpenAPI 3 specification (YAML)
#   GET  /fdp-index-proxy/openapi.yaml   → OpenAPI 3 specification (YAML)
#   GET  /fdp-index-proxy/proxy?id=<h>   → serve enriched RDF graph (FDP Index → proxy)
#   GET  /fdp-index-proxy/proxy?url=<u>  → same, legacy form (pre-0.11.0 registrations)
#   POST /fdp-index-proxy/proxy          → register a DCAT URL (publisher → proxy)
#   GET  /fdp-index-proxy/ping           → refresh all registered proxies (cron)
#
# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
def set_routes
  # ------------------------------------------------------------------ server
  set :server_settings, timeout: 180
  set :public_folder, "public"
  set :server, "webrick"
  set :bind, "0.0.0.0"
  set :environment, :production
  enable :cross_origin
  set :protection, except: :ip_spoofing

  # Fail fast on startup if required environment variables are missing.
  abort "FDP_PROXY_HOST not set"   unless ENV["FDP_PROXY_HOST"]
  abort "FDP_PROXY_METHOD not set" unless ENV["FDP_PROXY_METHOD"]
  abort "FDP_INDEX not set"        unless ENV["FDP_INDEX"]

  # ---------------------------------------------------------------- redirects
  get "/" do
    redirect "/fdp-index-proxy"
  end

  get "/fdp-index-proxy/" do
    redirect "/fdp-index-proxy"
  end

  # ------------------------------------------------------------ API spec root
  # Serves the OpenAPI 3 specification as YAML.
  get "/fdp-index-proxy" do
    content_type "application/yaml"
    send_file File.expand_path("../../openapi.yaml", __dir__)
  end

  # Canonical permalink for the spec — referenced in the spec's own +servers+ block.
  get "/fdp-index-proxy/openapi.yaml" do
    content_type "application/yaml"
    send_file File.expand_path("../../openapi.yaml", __dir__)
  end

  # ------------------------------------------ GET /proxy  (FDP Index → proxy)
  # Called by the FDP Index when it dereferences a registered proxy URL.
  # +id+ (a SHA-256 hex digest of the source URL) is the current, preferred
  # form — it's what {FDP.call_fdp_index} now registers, since it never needs
  # escaping and can't be corrupted by re-encoding on the Index's side.
  # +url+ (the raw/percent-encoded source URL) is accepted as a legacy
  # fallback for any already-registered clientUrl still using the old form.
  #
  # Flow:
  # 1. Resolve the source address from +id+ or +url+.
  # 2. Look up the enriched graph in the in-process cache.
  # 3. On a miss, rebuild by creating a new FDP object (re-fetch + re-enrich).
  # 4. Negotiate content type and return the graph as Turtle or JSON-LD.
  get "/fdp-index-proxy/proxy" do
    address =
      if params[:id]
        unless valid_proxy_id?(params[:id])
          warn "Rejected malformed id: #{params[:id].inspect}"
          halt 400, "id must be a 64-character SHA-256 hex digest"
        end
        found = FDP.address_for_id(params[:id])
        unless found
          warn "Unknown id: #{params[:id].inspect}"
          halt 400, "id not found in registry"
        end
        found
      elsif params[:url]
        unless valid_proxy_url?(params[:url])
          warn "Rejected invalid proxy URL: #{params[:url].inspect}"
          halt 400, "url must be a valid http or https URL"
        end
        params[:url]
      else
        halt 400, "id or url parameter required"
      end

    graph = FDP.load_graph_from_cache(url: address)

    unless graph
      # Cache miss — rebuild from source (also re-caches via FDP.new).
      # register: false — a GET must never mutate the persistent registry
      # (scanner ?url= probes pass the URL-shape validation above); only
      # POST /proxy and the cron ping register addresses.
      warn "Graph not found in cache for #{address}, attempting to rebuild"
      FDP.new(address: address, register: false)
      graph = FDP.load_graph_from_cache(url: address)
      halt 400 unless graph
    end

    negotiate_graph_response(graph)
  end

  # ----------------------------------------- POST /proxy  (publisher → proxy)
  # Called by a DCAT publisher to register their record with the FDP Index.
  # Expects a JSON body: +{ "clientUrl": "https://..." }+
  #
  # Flow:
  # 1. Parse the request body and extract +clientUrl+.
  # 2. Fetch, enrich, and cache the source DCAT record (FDP.new).
  # 3. Register the proxy URL with the FDP Index (FDP.call_fdp_index).
  post "/fdp-index-proxy/proxy" do
    body_str = request.body.read
    warn "RAW BODY RECEIVED: #{body_str.inspect}"

    halt 400, "Empty request body" if body_str.empty?

    begin
      request_payload = JSON.parse(body_str)
    rescue JSON::ParserError => e
      warn "Invalid JSON: #{e.message}"
      halt 400, "Invalid JSON payload"
    end

    client_url = request_payload["clientUrl"]
    halt 400, "Missing 'clientUrl' in payload" unless client_url
    unless valid_proxy_url?(client_url)
      warn "Rejected invalid clientUrl: #{client_url.inspect}"
      halt 400, "clientUrl must be a valid http or https URL"
    end

    warn "Processing clientUrl: #{client_url}"

    FDP.new(address: client_url)
    result = FDP.call_fdp_index(address: client_url)

    halt 500, "Failed to register with FDP index" unless result

    status 200
    { status: "success", message: "Registered #{client_url}" }.to_json
  end

  get "/fdp-index-proxy/ping" do  # called by a cron on a daily basis
    Thread.new { FDP.ping }  # run in background so the cron curl gets an immediate response
    status 200
    "pong"
  end
end
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

# Returns +true+ only if +url+ is a well-formed http/https URL with a
# recognisable hostname.  Rejects SQL-injection probes, bare numbers, and any
# other non-URL strings that automated scanners send as the +url+ parameter.
#
# @param url [String] the candidate URL
# @return [Boolean]
def valid_proxy_url?(url)
  return false unless url.is_a?(String) && url.match?(%r{\Ahttps?://}i)

  uri = URI.parse(url)
  # Require a non-empty hostname consisting only of valid DNS characters.
  !uri.host.nil? && uri.host.match?(/\A[a-zA-Z0-9]([a-zA-Z0-9\-.]*[a-zA-Z0-9])?\z/)
rescue URI::InvalidURIError
  false
end

# Returns +true+ only if +id+ looks like a SHA-256 hex digest (64 lowercase
# hex characters), as produced by {FDP.call_fdp_index} for the +id+ query
# parameter.
#
# @param id [String] the candidate id
# @return [Boolean]
def valid_proxy_id?(id)
  id.is_a?(String) && id.match?(/\A[a-f0-9]{64}\z/)
end

# Serialises +graph+ in the best format accepted by the client.
# Defaults to Turtle when the client sends no +Accept+ header or accepts +*/*+,
# since the FDP Index always accepts Turtle.
#
# @param graph [RDF::Graph] the enriched graph to serialise
# @return [void] halts the Sinatra request with the serialised body
def negotiate_graph_response(graph)
  request.accept.each do |type|
    case type.to_s
    when "application/json", "application/ld+json"
      content_type :json
      halt graph.dump(:jsonld)
    else
      content_type "text/turtle"
      halt graph.dump(:turtle)
    end
  end
  error 406
end
