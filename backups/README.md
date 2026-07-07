# Index entry snapshots

Point-in-time dumps of `GET https://tools.ostrails.eu/fdp-index/index/entries/all`
(public, read-only, no login required) — every entry currently registered with
the FDP Index. Taken before any bulk re-registration or cleanup so there's a
recovery reference, since the Index itself has no backup.

Each file is named `fdp-index-entries-snapshot-<UTC timestamp>.json`.
