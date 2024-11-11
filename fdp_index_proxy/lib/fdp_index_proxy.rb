# frozen_string_literal: true

require_relative "fdp_index_proxy/version"
require "swagger/blocks"
require "sinatra"
require "json"
require "erb"
require 'uri'
# require 'omniauth'
# require 'omniauth-openid-connect'
# require 'jwt'
require 'require_all'
require_relative  "cache"
require_relative  "metadata_functions"

require "json"
require "linkeddata"
require "rest-client"
require "require_all"
require "rdf/vocab"

require_all "."

module FdpIndexProxy
  class Error < StandardError; end
  # Your code goes here...
end
