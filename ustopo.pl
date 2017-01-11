#!/usr/bin/perl -w

# basic script for maintaining an offline copy of the US Topo map collection

use strict;

use Getopt::Std;
use Parse::CSV;
use File::Spec;
use File::Path qw( mkpath );
use File::Basename;

# parse command line options TODO error checking

# -C catalog file
# -D data directory
# TODO path format string for local file

my %opts;

getopts('C:D:', \%opts);

my $catalog = $opts{C};
my $datadir = $opts{D};

################################################################################
# generate the full file path for a given record - the argument is a hashref
sub get_local_path {
  my ($item) = @_;

  # sanitize the map name to get a file name
  my $filename = $item->{'Cell Name'};
  $filename =~ s/[^A-Za-z0-9_ -]/_/g;
  $filename .= '.pdf';

  # should be safe, but sanitize anyway
  my $state = $item->{'Primary State'};
  $state =~ s/[^A-Za-z0-9._-]/_/g;

  my $abs_datadir = File::Spec->rel2abs($datadir);

  File::Spec->join($abs_datadir, $state, $filename);
}

################################################################################
## MAIN ENTRY

my $csv = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') and ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

# run through the current items
while (my $item = $csv->fetch) {
  my $path = get_local_path($item);

  # if the file exists TODO and is current
  next if -f $path;

  # make necessary directories
  my $dirname = dirname($path);
  mkpath($dirname);

  printf("%s\n", $path);
}

