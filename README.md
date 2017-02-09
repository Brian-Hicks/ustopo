# NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

# SYNOPSIS

    ustopo.pl --data=dir [options]

# OPTIONS

- **--data=dir** : Directory location to save maps when downloading.
- **--update** : Update ScienceBase catalog (default behavior).
- **--no-update** : Do not update ScienceBase catalog.
- **--download** : Download new map items (default behavior).
- **--no-download** : Do not download new map items.
- **--mapname=string** : Specify the format string for map filenames.
- **--retry=num** : Number of retries for failed downloads (default=3).
- **--agent=string** : Override the User Agent string for the download client.
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

By default, `ustopo.pl` will perform regular maintenance on the catalog.  This includes updating
the catalog from ScienceBase, downloading new or modified items and deleted old or expired
records.  Other operations may be explicitly called by passing the appropriate command line
options.

The `--mapname` format string uses fields from the database as placeholders.  The default value
is `{State}/{MapName}.pdf` which will place the map in a subfolder by state.  Each placeholder
is placed in braces and will be expanded for each map.  For additional fields, see the database
schema for column names.

Browse the collection here: [https://www.sciencebase.gov/catalog/item/4f554236e4b018de15819c85](https://www.sciencebase.gov/catalog/item/4f554236e4b018de15819c85)

# REQUIREMENTS

- **Log::Message::Simple** - debug and logging output
- **Parse::CSV** - used to parse the catalog file
- **Mozilla::CA** - recommended for HTTPS connections

# TODO

- Remove files from the data directory that are not in the catalog (--prune).
- Improve check for a current file using PDF metadata, checksum, etc.
- Specify maximum number of maps to download per session (default to unlimited).
- Use a PID file.
- Mode to report catalog stats (--stats).
- Store configuration options in database (e.g. mapname, user agent, etc).
