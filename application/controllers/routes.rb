# frozen_string_literal: false

require_relative "../../lib/fdp_index_proxy"
require_relative "../../lib/fdp"

def set_routes(classes: allclasses)
  set :server_settings, timeout: 180
  set :public_folder, "public"
  set :server, "webrick"
  set :bind, "0.0.0.0"
  # set :views, "app/views"
  set :environment, :production
  enable :cross_origin
  set :protection, except: :ip_spoofing

  abort "FDP_PROXY_HOST not set" unless ENV["FDP_PROXY_HOST"]
  abort "FDP_PROXY_METHOD not set" unless ENV["FDP_PROXY_METHOD"]
  abort "FDP_INDEX not set" unless ENV["FDP_INDEX"]

  get "/" do
    redirect "/fdp-index-proxy"
  end
  get "/fdp-index-proxy/" do
    redirect "/fdp-index-proxy"
  end

  get "/fdp-index-proxy" do
    content_type :json
    response.body = JSON.dump(Swagger::Blocks.build_root_json(classes))
  end

  # this is the FDP Index calling us for a record
  get "/fdp-index-proxy/proxy" do  # ?url=https://....
    unless params[:url]
      error 400
      halt
    end

    graph = FDP.load_graph_from_cache(url: params[:url])
    warn graph.inspect
    warn graph.class

    unless graph  # might be false if it doesn't exist
      # this can happen if the cache has been erased or gone out of sync with the FDP index
      # try to create the record
      warn "the FDP endpoint is not found in teh cache, trying to recreate"
      _f = FDP.new(address: params[:url])
      warn "record is now frozen, calling attempt to load graph again"
      graph = FDP.load_graph_from_cache(url: params[:url])
      halt error 400 unless graph
    end

    request.accept.each do |type|
      case type.to_s
      when "text/turtle"
        content_type "text/turtle"
        halt graph.dump(:turtle)
      when "application/json"
        content_type :json
        halt graph.dump(:jsonld)
      when "application/ld+json"
        content_type :json
        halt graph.dump(:jsonld)
      else  # for the FDP index send turtle by default
        content_type "text/turtle"
        halt graph.dump(:turtle)
      end
    end
    error 406
  end

  # this is the DCAT site owner calling us to do a proxy of them
  post "/fdp-index-proxy/proxy" do
    body_str = request.body.read

    warn "RAW BODY RECEIVED: #{body_str.inspect}"  # debug line

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

    _f = FDP.new(address: client_url)
    result = FDP.call_fdp_index(address: client_url)

    halt 500, "Failed to register with FDP index" unless result

    status 200
    { status: "success", message: "Registered #{client_url}" }.to_json
  end

  get "/fdp-index-proxy/ping" do  # called by a cron on a weekly basis
    FDP.ping  # this uses the cache to re-call all FDPs and  re-calls the FDP Index for each one
    status 200
  end

  before do
  end

  # get '/login' do
  #   redirect '/auth/ls_aai'
  # end

  # # Callback route after OIDC authentication
  # get '/auth/ls_aai/callback' do
  #   auth = request.env['omniauth.auth']
  #   # Here you would typically save the auth info or tokens
  #   # For simplicity, let's just show what's received:
  #   puts auth.to_json
  #   "Login successful. Here's your auth info: #{auth.to_json}"
  # end

  # # Example protected route
  # get '/protected' do
  #   token = request.env['HTTP_AUTHORIZATION']&.split(' ')&.last
  #   if authorize_user(token)
  #     "Welcome! You are authorized to access this service."
  #   else
  #     status 401
  #     "Unauthorized"
  #   end
  # end

  # # Failure route for authentication errors
  # get '/auth/failure' do
  #   "Authentication failed: #{params['message']}"
  # end
  # =========================== AUTH
  # use OmniAuth::Builder do
  #   provider :openid_connect,
  #            :name => 'ls_aai',
  #            :issuer => 'your_issuer_url',
  #            :client_id => 'your_client_id',
  #            :client_secret => 'your_client_secret',
  #            :scope => 'openid profile email',
  #            :response_type => 'code',
  #            :redirect_uri => 'your_callback_url',
  #            :discovery => true
  # end

  # # Helper function to authorize user
  # def authorize_user(token)
  #   payload = JWT.decode(token, nil, false)[0]
  #   payload['permissions']&.include?('access_to_service')
  # end
end
