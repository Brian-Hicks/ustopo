#!/usr/bin/perl -w

# basic script for maintaining an offline copy of the US Topo map collection

use strict;

use Getopt::Long qw( :config bundling );
use Pod::Usage;

use Parse::CSV;
use File::Spec;
use File::Path qw( mkpath );
use File::Temp qw( tempfile );
use File::Basename;

use LWP::UserAgent;
use Archive::Zip;
use Time::HiRes qw( gettimeofday tv_interval );

use Log::Message::Simple qw( :STD :CARP );
use Data::Dumper;

################################################################################
# parse command line options
my $opt_silent = 0;
my $opt_verbose = 0;
my $opt_help = 0;
my $opt_catalog = undef;
my $opt_datadir = undef;
my $opt_agent = undef;

GetOptions(
  'catalog|C=s' => \$opt_catalog,
  'datadir|D=s' => \$opt_datadir,
  'silent|s' => \$opt_silent,
  'verbose|v' => \$opt_verbose,
  'agent=s' => \$opt_agent,
  'help|?' => \$opt_help,
) or pod2usage(1);

pod2usage(0) if $opt_help;

# TODO error cecking

my $catalog = File::Spec->rel2abs($opt_catalog);
my $datadir = File::Spec->rel2abs($opt_datadir);

my $silent = $opt_silent;
my $debug = ($opt_verbose) && (not $opt_silent);

################################################################################
# the common client for download files
my $client = LWP::UserAgent->new;

defined $opt_agent and $client->agent($opt_agent);
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

  my $pdf_path = get_local_path($item);
  debug("Checking for local file: $pdf_path", $debug);

  # TODO determine if the local file is up to date

  (-f $pdf_path) ? $pdf_path : undef;
}

################################################################################
# extract the first member of an archive to a specifc filename
sub extract_to {
  my ($zipfile, $tofile) = @_;

  # make necessary directories
  my $dirname = dirname($tofile);
  mkpath($dirname);

  my $zip = Archive::Zip->new($zipfile);
  croak 'Error loading archive.' unless defined $zip;

  # only process the first entry
  my @members = $zip->members;
  if (scalar(@members) == 0) {
    carp 'Empty archive.';
    return;
  } elsif (scalar(@members) > 1) {
    carp 'Unexpected entries in archive.';
    return;
  }

  my $entry = $members[0];

  debug('Extracting: ' . $entry->fileName, $debug);
  $entry->extractToFileNamed($tofile);
}

################################################################################
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch {
  my ($url) = @_;

  my $time_start = [gettimeofday];
  my $resp = $client->get($url);

  my $elapsed = tv_interval($time_start);
  my $dl_length = length($resp->decoded_content);
  my $mbps = ($dl_length / $elapsed) / (1024*1024);

  my $dl_status = sprintf('HTTP %s - %d bytes in %f seconds (%f MB/s)',
                          $resp->status_line, $dl_length, $elapsed, $mbps);

  debug($dl_status, $debug);

  if ($resp->is_error) {
    croak 'Error downloading file: ' . $resp->status_line;
  }

  # save the zipfile to a temporary file
  my ($fh, $tmpfile) = tempfile(UNLINK => 1);
  debug("Saving download: $tmpfile", $debug);

  binmode $fh;
  print $fh $resp->decoded_content;
  close $fh;

  return $tmpfile;
}

################################################################################
# download a specific item and return the path to the local file
sub download_item {
  my ($item) = @_;

  my $pdf_path = get_local_path($item);

  # download the zip file to a temp location
  my $zipfile = fetch($item->{'Download GeoPDF'});
  croak 'download error' unless -s $zipfile;

  extract_to($zipfile, $pdf_path);

  # TODO compare file size to item entry
  my $len_pdf = -s $pdf_path;
  my $len_item = $item->{'Byte Count'};
  debug("Extracted $len_pdf bytes", $debug);

  unlink $zipfile or carp $!;
  return $pdf_path;
}

################################################################################
## MAIN ENTRY

msg("Using data directory: $datadir", not $silent);
msg("Loading catalog: $catalog", not $silent);

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
  msg("Processing map: $mapname", not $silent);

  my $local_file = is_current($item);

  if ($local_file) {
    debug("Map is up to date: $local_file", $debug);
  } else {
    debug('Downloading map: ' . $item->{'Download GeoPDF'}, $debug);
    $local_file = download_item($item);
  }
}

__END__

=head1 NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

=head1 SYNOPSIS

  ustopo.pl --catalog=file --data=dir [options]

=head1 OPTIONS

=over 8

=item B<--catalog=file>
: CSV catalog file from The National Map project.

=item B<--data=dir>
: Directory location to save maps when downloading.

=item B<--agent=string>
: Set the User Agent string for the download client.

=item B<--verbose>
: Display extra logging output for debugging.

=item B<--silent>
: Supress all logging output (overrides --verbose).

=item B<--help>
: Print a brief help message and exit.

=back

=head1 DESCRIPTION

B<ustopo.pl> maintains a local repository of maps from the US Topo catalog.

Download the latest catalog here: L<https://geonames.usgs.gov/pls/topomaps/>

Use in accordance with the terms of the L<USGS|https://www2.usgs.gov/faq/?q=categories/9797/3572>.

=head1 IMPROVEMENTS

=over 8

=item Use ScienceBase API directly, rather than CSV catalog.

=item Generate browseable HTML file offline of maps.

=item Maintain local database of catalog for searching.

=item Remove files from the data directory that are not in the catalog.

=item Retry failed downloads (default to 3).

=item Specify maximum number of maps to download per session (default to unlimited).

=back

=cut
