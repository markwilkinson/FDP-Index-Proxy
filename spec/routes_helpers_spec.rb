# frozen_string_literal: true

require_relative "../application/controllers/routes"

# `valid_proxy_id?`/`valid_proxy_url?` are top-level helpers defined in
# routes.rb, used by `GET /fdp-index-proxy/proxy` to validate the `id`
# (preferred) and `url` (legacy) query parameters before trusting them.
RSpec.describe "proxy route validators" do
  describe "#valid_proxy_id?" do
    it "accepts a well-formed SHA-256 hex digest" do
      expect(valid_proxy_id?(Digest::SHA256.hexdigest("anything"))).to be true
    end

    it "rejects a value that isn't 64 hex characters" do
      expect(valid_proxy_id?("not-a-hash")).to be false
    end

    it "rejects uppercase hex (hexdigest always produces lowercase)" do
      expect(valid_proxy_id?("A" * 64)).to be false
    end

    it "rejects nil" do
      expect(valid_proxy_id?(nil)).to be false
    end
  end

  describe "#valid_proxy_url?" do
    it "accepts a well-formed https URL" do
      expect(valid_proxy_url?("https://example.org/catalog")).to be true
    end

    it "rejects a value with no scheme" do
      expect(valid_proxy_url?("example.org/catalog")).to be false
    end

    it "rejects non-URL scanner noise" do
      expect(valid_proxy_url?("1 OR 1=1")).to be false
    end
  end
end
