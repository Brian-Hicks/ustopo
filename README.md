# NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

# SYNOPSIS

    ustopo.pl --catalog=file --data=dir [options]

# OPTIONS

- **--catalog=file** : CSV catalog file from the USGS.
- **--data=dir** : Directory location to save maps when downloading.
- **--agent=string** : Set the User Agent string for the download client.
- **--verbose** : Display extra logging output for debugging.
- **--silent** : Supress all logging output (overrides --verbose).
- **--help** : Print a brief help message and exit.

# DESCRIPTION

**ustopo.pl** maintains a local repository of maps from the US Topo catalog.  The USGS produces
high-resolution PDF's that contain geospacial extensions for use in mobile applications such
as [Avenza PDF Maps](https://www.avenzamaps.com).  Additionally, the USGS makes these maps
available free for public use.  According to the USGS, about 75 maps are added to the catalog
each day.  The entire size of the catalog is approximately 1.5TB.

These maps are also suitable for printing.  They contain multiple layers, including topographic
lines, satellite imagery, road information & landmarks.  For best results, use an application
such as Adobe Acrobat Reader that allows you to configure which layers are visible.

In order to use **ustopo.pl**, you will need to download the latest CSV catalog.  This catalog
is updated regularly as a zip archive.  This script operates on the `topomaps_all.csv` file
in that archive.  It will only download current maps from the US Topo series.

Download the latest catalog here: [http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps\_all.zip](http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip)

Browse the collection here: [https://geonames.usgs.gov/pls/topomaps/](https://geonames.usgs.gov/pls/topomaps/)

Use in accordance with the terms of the [USGS](https://www2.usgs.gov/faq/?q=categories/9797/3572).

# REQUIREMENTS

- **Log::Message::Simple** - debug and logging output
- **Parse::CSV** - used to parse the catalog file
- **Mozilla::CA** - recommended for HTTPS connections

# TODO

- Use ScienceBase API directly, rather than CSV catalog.
- Generate browseable HTML file offline of maps.
- Maintain local database of catalog for searching.
- Remove files from the data directory that are not in the catalog.
- Improve check for a current file using PDF metadata.
- Retry failed downloads (default to 3).
- Specify maximum number of maps to download per session (default to unlimited).
- Use a lock file.
- Support custom filename formats using catalog fields.
