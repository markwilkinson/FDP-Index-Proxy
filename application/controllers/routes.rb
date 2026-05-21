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
#   GET  /fdp-index-proxy/proxy?url=<u>  → serve enriched RDF graph (FDP Index → proxy)
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
    send_file File.expand_path("../../../openapi.yaml", __dir__)
  end

  # Canonical permalink for the spec — referenced in the spec's own +servers+ block.
  get "/fdp-index-proxy/openapi.yaml" do
    content_type "application/yaml"
    send_file File.expand_path("../../../openapi.yaml", __dir__)
  end

  # ------------------------------------------ GET /proxy  (FDP Index → proxy)
  # Called by the FDP Index when it dereferences a registered proxy URL.
  # +url+ is the original source DCAT URL supplied at registration time.
  #
  # Flow:
  # 1. Look up the enriched graph in the in-process cache.
  # 2. On a miss, rebuild by creating a new FDP object (re-fetch + re-enrich).
  # 3. Negotiate content type and return the graph as Turtle or JSON-LD.
  get "/fdp-index-proxy/proxy" do
    halt 400 unless params[:url]

    graph = FDP.load_graph_from_cache(url: params[:url])

    unless graph
      # Cache miss — rebuild from source (also re-caches via FDP.new).
      warn "Graph not found in cache for #{params[:url]}, attempting to rebuild"
      FDP.new(address: params[:url])
      graph = FDP.load_graph_from_cache(url: params[:url])
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

    warn "Processing clientUrl: #{client_url}"

    FDP.new(address: client_url)
    result = FDP.call_fdp_index(address: client_url)

    halt 500, "Failed to register with FDP index" unless result

    status 200
    { status: "success", message: "Registered #{client_url}" }.to_json
  end

  # ------------------------------------------------- GET /ping  (cron trigger)
  # Intended for weekly cron calls.  Re-fetches every registered source URL,
  # rebuilds its enriched graph, and re-registers each proxy with the FDP Index.
  # Per-URL failures are caught inside FDP.ping and logged without aborting the run.
  get "/fdp-index-proxy/ping" do
    FDP.ping
    status 200
  end
end
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

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
