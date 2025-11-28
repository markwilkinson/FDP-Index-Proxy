
def thaw_keywords
  warn "thawing keyword cache"
  kwf = File.open("./cache/keywords.json", "r")
  kw = kwf.read
  kwf.close
  words = JSON.parse(kw)
  warn "keyword cache thawed #{words}"
  words
end

def freeze_keywords(words:)
  warn "freezing keyword cache"
  f = open("./cache/keywords.json", "w")
  f.puts words.to_json
  f.close
end

def thaw_servicetypes
  warn "thawing service type cache"
  kwf = File.open("./cache/servicetypes.json", "r")
  kw = kwf.read
  kwf.close
  words = JSON.parse(kw)
  warn "service type cache thawed #{words}"
  words
end

def freeze_servicetypes(types:)
  warn "freezing service type cache"
  f = open("./cache/servicetypes.json", "w")
  f.puts types.to_json
  f.close
end