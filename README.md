# NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

# SYNOPSIS

    ustopo.pl --catalog=file --data=dir [options]

# OPTIONS

- **--catalog=file**
: CSV catalog file from The National Map project.
- **--data=dir**
: Directory location to save maps when downloading.
- **--agent=string**
: Set the User Agent string for the download client.
- **--verbose**
: Display extra logging output for debugging.
- **--silent**
: Supress all logging output (overrides --verbose).
- **--help**
: Print a brief help message and exit.

# DESCRIPTION

**ustopo.pl** maintains a local repository of maps from the US Topo catalog.

Download the latest catalog here: [https://geonames.usgs.gov/pls/topomaps/](https://geonames.usgs.gov/pls/topomaps/)

Use in accordance with the terms of the [USGS](https://www2.usgs.gov/faq/?q=categories/9797/3572).

# IMPROVEMENTS

- Use ScienceBase API directly, rather than CSV catalog.
- Generate browseable HTML file offline of maps.
- Maintain local database of catalog for searching.
- Remove files from the data directory that are not in the catalog.
- Retry failed downloads (default to 3).
- Specify maximum number of maps to download per session (default to unlimited).
