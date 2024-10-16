# frozen_string_literal: false

def set_routes(classes: allclasses)
  set :server_settings, timeout: 180
  set :public_folder, 'public'

  get '/' do
    redirect '/fdp-index-proxy'
  end

  get '/fdp-index-proxy' do
    content_type :json
    response.body = JSON.dump(Swagger::Blocks.build_root_json(classes))
  end


  get '/flair-gg-vp-server/list' do
    @dcats = get_current
    # @message = 'All Resources'
    # request.accept.each do |type|
    #   case type.to_s
    #   when 'text/html'
    #     halt erb :discovered_layout
    #   when 'application/json'
    #     content_type :json
    #     halt @discoverables.to_json
    #   end
    # end
    # error 406 # @message = "All Resources"
  end

  before do
    @services = VP.current_vp.collect_data_services
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
