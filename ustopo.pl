#!/usr/bin/perl -w

# basic script for maintaining an offline copy of the US Topo map collection

use strict;

use Getopt::Std;
use Parse::CSV;
use File::Spec;
use File::Path qw( mkpath );
use File::Basename;
use LWP::Simple;
use LWP::UserAgent;

use Log::Message::Simple qw[:STD :CARP];
use Data::Dumper;

# parse command line options TODO error checking

# -C catalog file
# -D data directory
# -v debug logging
# -q silent mode
# -U custom user agent for download client
# TODO path format string for local file
my %opts;

getopts('C:D:U:qv', \%opts);

my $catalog = File::Spec->rel2abs($opts{C});
my $datadir = File::Spec->rel2abs($opts{D});

my $verbose = exists $opts{v};
my $silent = exists $opts{q};
my $debug = $verbose and not $silent;

################################################################################
# the common client for download files
my $client = LWP::UserAgent->new;
if (exists $opts{U}) {
  $client->agent($opts{U});
}

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
# determines if the local copy of item is current
sub current_item {
  my ($item) = @_;
  return undef;
}

################################################################################
# download a specific item and return the path to the local file
sub download_item {
  my ($item) = @_;

  my $path = get_local_path($item);

  # download the file to a temp location
  my $resp = $client->get($item->{'Download GeoPDF'});

  if ($resp->is_success) {
    print Dumper($resp->headers);
  } else {
    die $resp->status_line;
  }

  # make necessary directories
  my $dirname = dirname($path);
  mkpath($dirname);

  # extract the file in the new folder

  return $path;
}

################################################################################
## MAIN ENTRY

msg('Using data directory: ' . $datadir, not $silent);
msg('Loading catalog: ' . $catalog, not $silent);

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
  my $mapname = sprintf('%s [%s]', $item->{'Map Name'}, $item->{'Cell ID'});
  msg('Processing map: ' . $mapname, not $silent);

  my $local_file = current_item($item);

  if ($local_file) {
    debug('=> Map is up to date: ' . $local_file, $local_file);
  } else {
    debug('=> Downloading map: ' . $item->{'Download GeoPDF'}, $debug);
    $local_file = download_item($item);
  }

  die;
}

# search for files that shouldn't be in the data directory

