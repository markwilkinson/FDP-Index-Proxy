# frozen_string_literal: false

require_relative "../../lib/fdp_index_proxy"
require_relative "../../lib/fdp"

def set_routes(classes: allclasses)
  set :server_settings, timeout: 180
  set :public_folder, "public"
  set :server, 'webrick' 
  set :bind, "0.0.0.0"
  set :views, "app/views"
  enable :cross_origin


  abort "FDP_PROXY_HOST not set" unless ENV["FDP_PROXY_HOST"]
  abort "FDP_PROXY_METHOD not set" unless ENV["FDP_PROXY_METHOD"]
  abort "FDP_INDEX not set" unless ENV["FDP_INDEX"]


  get "/" do
    redirect "/fdp-index-proxy"
  end

  get "/fdp-index-proxy" do
    content_type :json
    response.body = JSON.dump(Swagger::Blocks.build_root_json(classes))
  end

  # this is the Index calling us for a record
  get "/fdp-index-proxy/proxy" do  # ?url=https://....
    unless params[:url]
      error 400
      halt
    end

    graph = FDP.load_graph_from_cache(url: params[:url])
    warn graph.inspect
    warn graph.class

    unless graph  # might be false if it doesn't exist
      error 400
      halt
    end
    # remove_from_cache(url: url)
    request.accept.each do |type|
      case type.to_s
      when 'text/turtle'
        content_type "text/turtle"
        halt graph.dump(:turtle)
      when 'application/json'
        content_type :json
        halt graph.dump(:jsonld)
      when 'application/ld+json'
        content_type :json
        halt graph.dump(:jsonld)
      else  # for the FDP index send turtle by default
        content_type "text/turtle"
        halt graph.dump(:turtle)
      end
    end
    error 406 
  end

  # this is the DCAT site owner calling us to do a proxy
  post "/fdp-index-proxy/proxy" do
    body = request.body.read
    warn "body is #{body}"
    # json = JSON.parse body
    # warn json.inspect
#    begin
      # curl -v -X POST   https://fdps.ejprd.semlab-leiden.nl/   -H 'content-type: application/json'   -d '{"clientUrl": "https://w3id.org/duchenne-fdp"}'
      request_payload = JSON.parse body
      warn request_payload.inspect
#    rescue StandardError => e
#      error 415
#      halt
#    end
#    unless request_payload["clientUrl"]
#      error 415
#      halt
#    end
    _f = FDP.new(address: request_payload["clientUrl"])
    warn "record is now frozen, calling fdp index"
    # the record is now frozen
    result = FDP.call_fdp_index(url: request_payload["clientUrl"])
    warn "called"
    # remove_from_cache(url: url)
    unless result
      error 500
    end
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
