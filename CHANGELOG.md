# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.13.0] - 2026-07-15

### Fixed
- **The registry-wipe bug** — the actual root cause of the recurring
  "all Index entries flip to Inactive" incidents. `FDP.register_url`
  persisted the registry by overwriting `cache/registry.json` with the
  **in-process** `@@url_registry` list, without ever reading the disk file
  first. Only `FDP.ping`/`FDP.address_for_id` hydrated the in-process list
  from disk, and only when it was empty. So after any container restart
  (`restart: always` makes these invisible), the first request that
  registered a new address before a ping/id-lookup had run — a manual
  `POST /proxy`, or even an automated scanner hitting `GET /proxy?url=junk`
  (whose failed build still called `register_url`) — rewrote the registry
  file as a 1-element array, silently dropping ~190 addresses from the
  nightly ping. Confirmed in production on 2026-07-15: `registry.json` had
  been reduced to ~4 addresses; the other 174 Index entries had received no
  ping since 2026-07-07 (`modificationTime` frozen) and all showed Inactive.
  All registry access now goes through a single mutex-guarded
  read-**merge**-write path: `register_url` unions disk + memory before
  appending, writes atomically (temp file + rename), and never shrinks the
  on-disk list; `ping` and `address_for_id` hydrate by union instead of
  replace-when-empty.
- `GET /fdp-index-proxy/proxy` no longer registers addresses at all
  (`FDP.new(register: false)` on its cache-miss rebuild path). Dereferencing
  is read-only: legacy `?url=` callbacks and scanner probes (which pass the
  URL-shape validation) could previously insert junk addresses into the
  registry, which the nightly cron then dutifully registered with the FDP
  Index forever (one such junk entry, first pinged 2026-07-12, is sitting
  in the production Index as INVALID). Only `POST /proxy` and the cron ping
  register addresses now.

### Added
- `FDP.ping` logs `PING CYCLE START: <n> registered URLs` and
  `PING CYCLE COMPLETE: <ok> succeeded, <failed> failed, of <n>` so a
  short or partially failing cycle is finally visible in `docker logs`
  (previous "silently skipped" addresses had no trace at all).
- Regression specs for the registry: merge-not-overwrite after a simulated
  process restart; no file rewrite when the URL is already registered;
  ping over the union of disk + memory; and `register: false` never
  touching the registry on either the successful- or failed-build path.
  The spec suite now points `FDP::REGISTRY_PATH` at a temp file (new
  `FDP_REGISTRY_PATH` env override) instead of stubbing `File.write`
  globally, so persistence behaviour is actually exercised.

### Operational notes (production, 2026-07-15)
- The FDP Index at `tools.ostrails.eu/fdp-index` had `ping.validDuration`
  set to `PT24H` (not the 7-day default), so entries showed Inactive within
  24 h of any missed ping. Raised to `PT168H` (7 days) via the settings API.
- Production `cache/registry.json` must be restored from
  `backups/merged_registry_2026-07-07.json` when deploying this release.

## [0.12.0] - 2026-07-07

### Fixed
- `query_toplevel` only recognized `dcat:Catalog`/`Dataset`/`Distribution`/
  `DataService` as top-level types. Records typed *only* with an FTR
  (`https://w3id.org/ftr#`) core class and no accompanying `dcat:*` type
  (e.g. OpenAIRE's `ftr:Test` test records) resolved to `toptype = nil`,
  which correctly (per the v0.10.0 fix) skipped caching entirely — so these
  live, well-formed records could never be served through the proxy at all.
- `find_subject_uri_query` reconstructed a `dcat:` URI from a short type
  name (e.g. `"DataService"` → `dcat:DataService`), which can't find a
  subject typed only with a non-`dcat:`-namespaced equivalent class. Changed
  to accept the full candidate type URIs directly and match any of them via
  a SPARQL `VALUES` clause.

### Added
- `ftr:Test` and `ftr:ScoringAlgorithm` are now recognized as DataService
  equivalents (`ftr:Test` is formally `rdfs:subClassOf dcat:DataService` per
  the FTR ontology); `ftr:Metric` and `ftr:Benchmark` are recognized as
  generic `dcat:Resource` equivalents (see `FDP::FTR_TYPE_EQUIVALENTS` in
  `lib/fdp.rb`). `find_dcat_classes` (`lib/queries.rb`) extended to include
  all four in its LDP-container-injection query, and `inject_class_container`
  normalizes them to their mapped category.
- `inject_FDP_root` now also injects `r3d:Repository`
  (`http://www.re3data.org/schema/3-0#Repository`) on the synthetic FDP root,
  alongside the existing `fdp-o:MetadataService` — the Index's
  `findRepository()` accepts either, so this is future-proofing in case the
  Index's requirements are ever tightened to R3D only.
- Regression tests in `spec/fdp_spec.rb` covering: an `ftr:Test`-only record
  building as a DataService, an `ftr:Metric`-only record building as a
  Resource, and both `fdp-o:MetadataService`/`r3d:Repository` being present
  on the FDP root.

## [0.11.0] - 2026-07-07

### Fixed
- The v0.10.0 percent-encoding fix for `clientUrl` (`URI.encode_www_form_component`)
  changed the exact byte string of every already-registered entry's `clientUrl`
  (raw/unencoded before, percent-encoded after). Since the FDP Index matches
  `clientUrl` by **exact string** (`findByClientUrl`), every pre-existing
  registration was silently orphaned the moment this proxy started sending the
  new encoded form on its daily ping — the Index no longer recognised the
  incoming ping as belonging to the existing entry, so `lastRetrievalTime`
  stopped advancing for it and it eventually flipped to Inactive. Confirmed in
  production: an entry registered 2026-05-13 stopped receiving automated
  `IncomingPing`/`MetadataRetrieval` events after this proxy's encoding fix
  went live, despite the daily cron demonstrably still running.
- Separately, live logs showed the Index's own HTTP client re-encoding an
  already-percent-encoded `url` query value on (at least) one of its internal
  request paths, doubly mangling it (`%3A` → `%253A`) and getting rejected by
  this proxy's own validation — a second, independent failure mode layered on
  top of the same root cause: embedding an encoded URL in the `clientUrl`
  query string is fragile against any encode/decode assumption mismatch
  between this proxy and the Index.

### Changed
- `FDP.call_fdp_index` now registers `clientUrl` as
  `.../fdp-index-proxy/proxy?id=<sha256(address)>` — an opaque SHA-256 hex
  digest of the source address — instead of embedding the (encoded) address
  itself. A hex digest has no characters that ever need escaping, so it can't
  be corrupted by any encode/decode step on either side, and it depends only
  on the source address, not on this proxy's escaping logic — so it can never
  again drift out of sync with a previously-registered Index entry the way
  the v0.10.0 encoding change did.
- `GET /fdp-index-proxy/proxy` now accepts `id=<sha256 hex>` (preferred,
  resolved against the on-disk registry via new `FDP.address_for_id`) and
  still accepts the legacy `url=<address>` form, so already-registered
  clientUrls continue to resolve until they're naturally replaced.
- `openapi.yaml` updated: `id` and `url` are now both optional query
  parameters on `GET /fdp-index-proxy/proxy` (exactly one required at the
  application level).

**Migration note:** entries registered before this release (any entry whose
Index-side `clientUrl` still contains `?url=...`) are orphaned regardless —
they stopped receiving automated retrievals as soon as v0.10.0 shipped. They
won't self-heal; re-run `FDP.ping` (or `GET /fdp-index-proxy/ping`) to
re-register them under the new `?id=...` form, and manually remove the stale
duplicate entries left behind in the Index admin UI.

### Added
- First real spec suite for this project (`spec/fdp_spec.rb`,
  `spec/routes_helpers_spec.rb`; `spec/spec_helper.rb` now actually loads the
  app and resets `FDP`'s cache/registry class variables between examples).
  Covers: `FDP.address_for_id` registry lookups; `FDP.call_fdp_index`
  producing an id-based `clientUrl` that never contains the source address
  (including addresses with their own query string — the case that motivated
  the original, broken encoding fix); the cache-preservation-on-failed-rebuild
  regression from v0.10.0; and the `id`/`url` query-parameter validators used
  by `GET /fdp-index-proxy/proxy`. All outbound HTTP (`RestClient::Request`)
  is stubbed — no real network calls or writes to the tracked
  `cache/registry.json`.
- `.rubocop.yml`: excluded `spec/**/*` from `Metrics/BlockLength` (standard
  RSpec convention — example groups routinely exceed the default block-length
  limit).

## [0.10.0] - 2026-07-03

### Fixed
- `FDP.call_fdp_index` interpolated the source `address` raw into the
  `clientUrl` query string with no escaping. Any source URL containing its
  own query string (`&`, `=`, `#`, `+`, spaces) corrupted the round trip: the
  FDP Index's callback `GET /fdp-index-proxy/proxy?url=...` would receive a
  truncated `url` param that no longer matched the SHA-256 cache key computed
  at registration time, forcing a rebuild against a truncated (possibly
  non-resolving) URL. Now uses `URI.encode_www_form_component(address)`.
- `FDP#initialize` ran `cache_store` unconditionally even when the origin
  fetch failed or returned unparseable content, silently overwriting a
  previously-cached good graph with an empty one under the same key (the
  next Index callback would then see an empty Turtle body and flip the
  record to `Invalid`). `cache_store` is now skipped whenever `@graph` is
  empty or `@toptype` could not be resolved, preserving the last good cached
  graph; the URL is still added to the registry either way so cron keeps
  retrying it.

### Changed
- Corrected `FDP.ping`'s docstring, which claimed the refresh was "intended
  to be triggered weekly" — the actual configured cron (Dockerfile,
  `cron instructions`) has always been daily (`0 0 * * *`).
- Filled in the previously-empty `cron instructions` file with the actual
  cron schedule and process/replica-count notes.

## [0.9.0] - 2026-05-29

### Changed
- `FDP_CACHE_TTL` set to `600` (10 minutes) in `docker-compose.yml`.
  Previously the default of 86 400 s (24 h) meant a modified source record
  would not be reflected by the proxy until the next day.  With a 10-minute
  TTL, changes propagate within one FDP Index polling cycle.

## [0.8.0] - 2026-05-28

### Fixed
- All three `RestClient::Request.execute` calls (`load`, `testresolution`,
  `call_fdp_index`) lacked timeout parameters, causing `/ping` to hang
  indefinitely whenever a source URL was slow or unreachable.  Added
  `timeout: 30` and `open_timeout: 10` to each call so a stuck URL skips
  after at most 30 seconds rather than blocking the WEBrick thread forever.
- Volume mount in `docker-compose.yml` pointed to
  `/server/fdp_index_proxy/cache` instead of `/server/cache`, so
  `registry.json` was never persisted to the host and was lost on every
  container restart.

### Changed
- Cron schedule changed from weekly (`0 0 * * 0`) to daily (`0 0 * * *`)
  so registrations are refreshed before the FDP Index marks them inactive.
- Removed dead `command:` override from `docker-compose.yml` (the
  Dockerfile `ENTRYPOINT` made it a no-op; it also referenced a
  non-existent path).

## [0.7.0] - 2026-05-21

### Fixed
- 500 error on all POST requests caused by `committee` calling `rewind` on
  WEBrick's `rack.input`, which does not implement that method.  A small
  body-buffering middleware now wraps `rack.input` in a `StringIO` before
  `committee` reads it, so both the validator and the route handler can read
  the body without conflict.

## [0.6.0] - 2026-05-21

### Added
- `valid_proxy_url?` helper in `routes.rb` validates that any incoming `url` or
  `clientUrl` value is a well-formed `http`/`https` URL with a recognisable
  hostname before the route handler processes it.  Rejects SQL-injection probes
  and other non-URL strings sent by automated scanners; logs the rejected value
  and returns 400.
- `pattern: '^https?://'` constraint added to the `url` query parameter and
  `clientUrl` body field in `openapi.yaml`, so `committee` middleware rejects
  non-HTTP values at the Rack layer before they reach route code.

## [0.5.0] - 2026-05-21

### Added
- `committee` gem (~> 5.0) for runtime request validation against `openapi.yaml`.
  Malformed query parameters and request bodies are rejected at the Rack middleware
  layer before reaching route handlers.  Response validation is deliberately omitted
  since responses are opaque RDF blobs.

## [0.4.0] - 2026-05-21

### Removed
- `swagger-blocks` gem dependency — entirely replaced by the static `openapi.yaml`
  introduced in v0.3.0.
- `swagger_root` block and `SWAGGERED_CLASSES` constant from
  `application_controller.rb`.
- `ErrorModel` class from `models.rb` (existed solely to satisfy the Swagger schema);
  file moved to `deprecated/`.
- `require "swagger/blocks"` from `lib/fdp_index_proxy.rb`.
- `_classes` parameter from `set_routes` (no longer has any callers).
- `require_relative "models"` from `application_controller.rb`.

## [0.3.0] - 2026-05-21

### Added
- YARD documentation on every class and public method in `lib/fdp.rb` and
  `lib/queries.rb`, covering `@param`, `@return`, and inline flow commentary
  explaining the why behind non-obvious logic.
- Inline step-by-step comments in all three route handlers in `routes.rb`,
  describing the processing flow for each request type.
- `openapi.yaml` — a static OpenAPI 3.0.3 specification covering all four
  routes (`GET /proxy`, `POST /proxy`, `GET /ping`, `GET /openapi.yaml`),
  with request/response schemas, examples, and environment-variable documentation.
- New route `GET /fdp-index-proxy/openapi.yaml` that serves the spec as
  `application/yaml`. The root `GET /fdp-index-proxy` now also serves the
  OpenAPI 3 spec, replacing the legacy Swagger 2.0 JSON endpoint.
- `negotiate_graph_response` helper extracted from the GET /proxy handler to
  encapsulate content negotiation (Turtle / JSON-LD) and reduce block length.

### Changed
- `set_routes` parameter renamed from `classes:` to `_classes:` (the Swagger
  class list is no longer used now that the spec is static YAML).
- Duplicate `text/turtle` / `else` branch in content negotiation collapsed into
  a single `else` clause that defaults to Turtle for any unrecognised type.
- Removed empty `before do end` block from `routes.rb`.

## [0.2.0] - 2026-05-21

### Changed
- Replaced Marshal-based disk cache with an in-process in-memory cache (`@@cache`
  class variable). For large DCAT records (potentially hundreds of thousands of
  triples) this gives instant graph retrieval on cache hits, avoiding both disk I/O
  and the cost of re-parsing RDF. The previous approach serialised the entire `FDP`
  object to a `.marsh` file, which was also fragile across Ruby version and gem
  upgrades.
- URL registry is now persisted to `./cache/registry.json` as a plain JSON array of
  registered source URLs. This replaces the collection of per-record `.marsh` files
  as the durable store that the weekly ping reads after a process restart.
- Cache TTL is now configurable via the `FDP_CACHE_TTL` environment variable
  (integer seconds). Defaults to `86400` (24 hours). The previous hard-coded value
  was 120 seconds (2 minutes), which caused unnecessary re-fetches from source on
  nearly every FDP Index request.
- `ping` now catches per-URL errors and continues refreshing remaining entries,
  rather than aborting the whole cycle on the first failure.

### Fixed
- `parse_fdp` referenced undefined local variable `statement` instead of the block
  variable `s`, causing a `NameError` at runtime whenever an FDP-native record was
  processed.
- SPARQL queries in `lookup_parent` and `clarify_data_service_parent` used the
  prefix `fdcat:service`, which was never declared in `NAMESPACES`. Corrected to
  `dcat:service`.

### Removed
- `lib/metadata_functions.rb` (ontology label lookups: EDAM, EBI, NCBO, Bio2RDF,
  Ontobee, schema.org, etc.) moved to `deprecated/`. This functionality was
  prototyped for a VP search feature that is out of scope for the proxy.
- `lib/cache.rb` (keyword and service-type JSON cache helpers) moved to
  `deprecated/`. These were remnants of the same VP search feature and unused by
  the core proxy pipeline.

## [0.1.0] - initial release

- Initial prototype: proxies a source DCAT record, injects FDP-required triples
  (FAIRDataPoint root, LDP DirectContainers, vpConnection/VPDiscoverable
  annotations), registers the proxied record with an FDP Index, and re-pings the
  Index on a weekly cron schedule.
