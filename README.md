# US Topo Downloader

Download and maintain a local catalog of all current US Topo maps.

Catalog information (including current version): https://geonames.usgs.gov/pls/topomaps/

Use in accordance with the terms of the [USGS](https://www2.usgs.gov/faq/?q=categories/9797/3572).

## Requirements

[Parse::CSV](http://search.cpan.org/~kwilliams/Parse-CSV-2.04/lib/Parse/CSV.pm)

## Usage

ustopo.pl -C topomaps_all.csv -D /path/to/maps/data

## Improvements

* Use ScienceBase API directly, rather than CSV catalog
* Generate browseable HTML file offline of maps
* Maintain local database of catalog for searching
