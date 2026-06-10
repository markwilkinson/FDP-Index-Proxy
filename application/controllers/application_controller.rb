# frozen_string_literal: false

require_relative "../../lib/fdp_index_proxy"

require_relative "routes"

module FdpIndexProxy
  class Main < Sinatra::Application
    FileUtils.mkdir_p("./cache") unless Dir.exist?("./cache")

    # WEBrick's rack.input does not implement rewind, which committee requires
    # after reading the body for validation.  Buffer it into a StringIO first
    # so that the route handler can read it again afterwards.
    use(Class.new do
      def initialize(app) = @app = app

      def call(env)
        env["rack.input"] = StringIO.new(env["rack.input"].read)
        @app.call(env)
      end
    end)

    # Validate incoming requests against the OpenAPI 3 spec.
    # Rejects malformed query parameters and request bodies before they reach
    # the route handlers.  Response validation is intentionally omitted since
    # responses are always opaque RDF blobs.
    use Committee::Middleware::RequestValidation,
        schema_path: File.expand_path("../../openapi.yaml", __dir__),
        error_handler: ->(e, _env) { warn "Committee validation error: #{e.message}" },
        ignore_error: false

    before do
      response.headers["Access-Control-Allow-Origin"] = "*"
    end

    options "*" do
      response.headers["Allow"] = "GET, PUT, POST, DELETE, OPTIONS"
      response.headers["Access-Control-Allow-Headers"] =
        "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
      response.headers["Access-Control-Allow-Origin"] = "*"
      200
    end

    set_routes
  end
end
