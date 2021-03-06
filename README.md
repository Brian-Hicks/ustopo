# NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

# SYNOPSIS

    ustopo.pl --catalog=file --data=dir [options]

# OPTIONS

- **--config=cfg** : Load options from specific config file.
- **--data=dir** : Directory location to save maps when downloading.
- **--catalog=file** : CSV catalog file from the USGS.
- **--download** : Download all new map items (default behavior).
- **--download=max** : Download up to max items (0 = no limit).
- **--no-download** : Do not download new map items.
- **--prune** : Remove extra files from data directory.
- **--no-prune** : Do not remove extra files (default behavior).
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

To control the number of downloads, use the `--download=max` option.  Specifying a `max` value
of `0` will enable unlimited downloads.  Otherwise, the program will only download up to the
given value.  A negative value will disable all downloads (identical to `--no-download`).  Note
that failed downloads do not count against the maximum.

The `--mapname` format string uses fields from the catalog as placeholders.  The default value
is `{Primary State}/{Map Name}.pdf` which will place the map in a subfolder by state.  Each
placeholder is placed in braces and will be expanded for each map.  For additional fields, read
the `readme.txt` file included with the catalog.

Download the latest catalog here: [http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps\_all.zip](http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip)

Browse the collection here: [https://geonames.usgs.gov/pls/topomaps/](https://geonames.usgs.gov/pls/topomaps/)

Use in accordance with the terms of the [USGS](https://www2.usgs.gov/faq/?q=categories/9797/3572).

# REQUIREMENTS

- **Log::Log4Perl** - debug and logging output
- **Parse::CSV** - used to parse the catalog file
- **Mozilla::CA** - recommended for HTTPS connections

# TODO

- Automatically download the latest catalog.
- Save catalog to a local database for improved searching.
- Use a PID file.
- Load config options from file.
