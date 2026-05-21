# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
