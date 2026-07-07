# frozen_string_literal: true

RSpec.describe FDP do
  let(:address) { "https://tests.example.org/tests/some_test" }

  describe ".address_for_id" do
    it "resolves a previously-registered address by its SHA-256 id" do
      FDP.register_url(address)
      id = Digest::SHA256.hexdigest(address)

      expect(FDP.address_for_id(id)).to eq(address)
    end

    it "returns nil for an id that was never registered" do
      expect(FDP.address_for_id("0" * 64)).to be_nil
    end
  end

  describe ".call_fdp_index" do
    around do |example|
      original = ENV.to_h.slice("FDP_INDEX", "FDP_PROXY_HOST", "FDP_PROXY_METHOD")
      ENV["FDP_INDEX"] = "https://index.example.org/"
      ENV["FDP_PROXY_HOST"] = "proxy.example.org"
      ENV["FDP_PROXY_METHOD"] = "https"
      example.run
      original.each { |k, v| ENV[k] = v }
    end

    # Regression test for the v0.10.0 -> v0.11.0 fix: clientUrl must never
    # embed the address (raw or encoded) at all, only an opaque digest of it —
    # so its exact-match lookup on the Index side can never again drift when
    # this proxy's escaping logic changes.
    it "registers clientUrl as an opaque SHA-256 id, never the address itself" do
      expected_id = Digest::SHA256.hexdigest(address)
      sent_payload = nil

      allow(RestClient::Request).to receive(:execute) do |args|
        sent_payload = JSON.parse(args[:payload])
        instance_double(RestClient::Response, body: "ok")
      end

      FDP.call_fdp_index(address: address)

      expect(sent_payload["clientUrl"])
        .to eq("https://proxy.example.org/fdp-index-proxy/proxy?id=#{expected_id}")
      expect(sent_payload["clientUrl"]).not_to include(address)
    end

    # This is the case that motivated the original (broken) URL-encoding fix:
    # a source address with its own query string. The id-based scheme sidesteps
    # it entirely — nothing about the address ever appears in the query string,
    # so there's nothing to escape and nothing for a re-encoding step on the
    # Index's side to mangle.
    it "is unaffected by query-string characters in the source address" do
      tricky_address = "https://example.org/data?resource=graph1&format=ttl#frag"
      expected_id = Digest::SHA256.hexdigest(tricky_address)
      sent_payload = nil

      allow(RestClient::Request).to receive(:execute) do |args|
        sent_payload = JSON.parse(args[:payload])
        instance_double(RestClient::Response, body: "ok")
      end

      FDP.call_fdp_index(address: tricky_address)

      expect(sent_payload["clientUrl"])
        .to eq("https://proxy.example.org/fdp-index-proxy/proxy?id=#{expected_id}")
    end
  end

  describe "cache preservation when a rebuild fails (regression)" do
    let(:good_ttl) do
      <<~TURTLE
        @prefix dcat: <http://www.w3.org/ns/dcat#> .
        <http://example.org/dataset1> a dcat:Dataset .
      TURTLE
    end

    # A failed/unparseable origin fetch must not silently overwrite a
    # previously-cached good graph with an empty one (that used to happen
    # unconditionally via cache_store; see CHANGELOG v0.10.0).
    it "keeps serving the last good graph when a later rebuild can't fetch anything" do
      allow(RestClient::Request).to receive(:execute).and_return(
        instance_double(RestClient::Response, body: good_ttl.dup)
      )
      FDP.new(address: address)
      good_graph = FDP.load_graph_from_cache(url: address)
      expect(good_graph.size).to be_positive

      allow(RestClient::Request).to receive(:execute).and_raise(StandardError, "network down")
      FDP.new(address: address)

      expect(FDP.load_graph_from_cache(url: address)).to equal(good_graph)
    end

    it "still registers the address so cron keeps retrying it, even on a first-ever failure" do
      allow(RestClient::Request).to receive(:execute).and_raise(StandardError, "network down")

      FDP.new(address: address)

      expect(FDP.load_graph_from_cache(url: address)).to be false
      expect(FDP.address_for_id(Digest::SHA256.hexdigest(address))).to eq(address)
    end
  end
end
