require "linkeddata"
class JSON::Ext::Generator::State
  # monkey patch due to incompatibilities between linkeddata gem and json-ld
  def except(*keys)
    # Convert to real Hash, drop keys, then reconstruct (safe since to_h exists)
    to_h.except(*keys)
  end
end

g = RDF::Graph.load("https://ftp.uniprot.org/pub/databases/uniprot/current_release/rdf/void.rdf")
puts g.size
