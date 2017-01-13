#!/usr/bin/perl -w

# basic script for maintaining an offline copy of the US Topo map collection

use strict;

use Getopt::Std;
use Parse::CSV;
use File::Spec;
use File::Path qw( mkpath );
use File::Temp qw( tempfile tempdir );
use File::Basename;
use LWP::UserAgent;
use Archive::Zip;

use Log::Message::Simple qw[:STD :CARP];
use Data::Dumper;

# parse command line options TODO error checking

# -C catalog file
# -D data directory
# -U custom user agent for download client
# -m set max number of items to download
# -r set max number of retries
# -v debug logging
# -q silent mode
# TODO path format string for local file
my %opts;

getopts('C:D:U:m:qv', \%opts);

my $catalog = File::Spec->rel2abs($opts{C});
my $datadir = File::Spec->rel2abs($opts{D});

my $max_dl = $opts{m} || 0;
my $retry_dl = $opts{r} || 3;

my $verbose = exists $opts{v};
my $silent = exists $opts{q};
my $debug = ($verbose) && (not $silent);

################################################################################
# the common client for download files
my $client = LWP::UserAgent->new;

exists $opts{U} and $client->agent($opts{U});
debug('User Agent: ' . $client->agent, $debug);

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
sub is_current {
  my ($item) = @_;

  my $path = get_local_path($item);
  debug('Checking local file: ' . $path, $debug);

  # TODO determine if the local file is up to date

  (-f $path) ? $path : undef;
}

################################################################################
# download a specific item and return the path to the local file
sub download_item {
  my ($item) = @_;

  my $path = get_local_path($item);

  # download the zip file to a temp location
  my $resp = $client->get($item->{'Download GeoPDF'});

  # TODO log size of dowloaded file
  # TODO log bytes / sec after download?
  debug($resp->status_line, $debug);
  die $resp->status_line if ($resp->is_error);

  # save the zipfile to a temporary file
  my ($fh, $zipfile) = tempfile(UNLINK => 1);
  debug('Saving download: ' . $zipfile, $debug);

  binmode $fh;
  print $fh $resp->decoded_content;
  close $fh;

  # make necessary directories
  my $dirname = dirname($path);
  mkpath($dirname);

  # TODO error checking on the archive
  # TODO examine size against catalog?

  # extract the file in the new folder
  my $zip = Archive::Zip->new($zipfile);
  my @members = $zip->members;
  my $entry = $members[0];

  debug('Extracting: ' . $entry->fileName, $debug);
  $entry->extractToFileNamed($path);

  unlink $zipfile;
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
    (($_->{'Series'} eq 'US Topo') && ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

# run through the current items
while (my $item = $csv->fetch) {
  my $mapname = sprintf('%s [%s]', $item->{'Map Name'}, $item->{'Cell ID'});
  msg('Processing map: ' . $mapname, not $silent);

  my $local_file = is_current($item);

  # TODO monitor download count

  if ($local_file) {
    debug('Map is up to date: ' . $local_file, $debug);
  } else {
    debug('Downloading map: ' . $item->{'Download GeoPDF'}, $debug);
    $local_file = download_item($item);

    # TODO retry failed downloads
  }
}

# search for files that shouldn't be in the data directory

