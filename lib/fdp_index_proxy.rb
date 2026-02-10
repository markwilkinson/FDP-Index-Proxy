# frozen_string_literal: true

# require_relative "fdp_index_proxy/version"
require "dotenv/load" unless ENV["RACK_ENV"] == "production"
require "swagger/blocks"
require "sinatra"
require "json"
require "erb"
require "uri"
require "fileutils"
# require 'omniauth'
# require 'omniauth-openid-connect'
# require 'jwt'
require "require_all"
require_relative  "cache"
require_relative  "metadata_functions"
require_relative  "queries"
require_relative  "fdp"

require "linkeddata"
require "rest-client"
require "rdf/vocab"

require_all "./lib"

module FdpIndexProxy
  class Error < StandardError; end
end
