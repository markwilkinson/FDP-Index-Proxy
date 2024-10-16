# frozen_string_literal: false

#require_relative '../../config/environment' # for docker
require 'swagger/blocks'
require 'sinatra'
#require 'sinatra/base'
require 'json'
require 'erb'
# require 'omniauth'
# require 'omniauth-openid-connect'
#require 'jwt'

# DO NOT change the order of loading below.  The files contain executable code that builds the overall configuration before this module starts
require_relative '../../lib/configuration' # VPConfig and FDPConfig
require_relative 'models'
require_relative 'routes'

class ApplicationController < Sinatra::Application
  include Swagger::Blocks

  set :bind, '0.0.0.0'
  before do
    response.headers['Access-Control-Allow-Origin'] = '*'
  end

  configure do
    set :public_folder, 'public'
    set :views, 'app/views'
    enable :cross_origin
  end

  # routes...
  options '*' do
    response.headers['Allow'] = 'GET, PUT, POST, DELETE, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token'
    response.headers['Access-Control-Allow-Origin'] = '*'
    200
  end

  swagger_root do
    key :swagger, '2.0'
    info do
      key :version, '1.0.0'
      key :title, 'FDP Index Proxy'
      key :description, 'Adds metadata to DCAT so that it can be consumed by FDP Index'
      key :termsOfService, 'https://example.org'
      contact do
        key :name, 'Mark D. Wilkinson'
      end
      license do
        key :name, 'MIT'
      end
    end
    
    key :schemes, ['http']
    key :host, ENV.fetch('HARVESTER', nil)
    key :basePath, '/fdp_index_proxy'
    #    key :consumes, ['application/json']
    #    key :produces, ['application/json']
  end

  # A list of all classes that have swagger_* declarations.
  SWAGGERED_CLASSES = [ErrorModel, self].freeze

  set_routes(classes: SWAGGERED_CLASSES)

  #VP.new(config: VPConfig.new) # set up index and active sites)

  run! # if app_file == $PROGRAM_NAME
end
