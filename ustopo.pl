#!/usr/bin/perl -w

use strict;

use Getopt::Std;
use Parse::CSV;

# parse command line options TODO error checking

# -C catalog file
# -D data directory

my %opts;

getopts('C:D:', \%opts);

my $catalog = $opts{C};
my $datadir = $opts{D};

################################################################################
## MAIN ENTRY

my $items = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') and ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

# run through the current items
while (my $item = $items->fetch) {
  printf("%s\n", $item->{'Map Name'});
}
