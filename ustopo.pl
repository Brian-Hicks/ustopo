#!/usr/bin/perl -w

=pod

=head1 NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

=head1 SYNOPSIS

  ustopo.pl --catalog=file --data=dir [options]

=cut

################################################################################

use strict;

use Getopt::Long qw( :config bundling );
use Scalar::Util qw( looks_like_number );
use Pod::Usage;

use Parse::CSV;
use File::Spec;
use File::Path qw( mkpath );
use File::Temp qw( tempfile );
use File::Basename;
use File::Find;

use LWP::UserAgent;
use Archive::Zip qw( :ERROR_CODES );
use Time::HiRes qw( gettimeofday tv_interval );

use Log::Message::Simple qw( :STD :CARP );
use Data::Dumper;

################################################################################

=pod

=head1 OPTIONS

=over

=item B<--catalog=file> : CSV catalog file from the USGS.

=item B<--data=dir> : Directory location to save maps when downloading.

=item B<--download> : Download new map items (default behavior).

=item B<--no-download> : Do not download new map items.

=item B<--prune> : Remove extra files from data directory.

=item B<--no-prune> : Do not remove extra files (default behavior).

=item B<--mapname=string> : Specify the format string for map filenames.

=item B<--retry=num> : Number of retries for failed downloads (default=3).

=item B<--agent=string> : Override the User Agent string for the download client.

=item B<--verbose> : Print informational messages (-vv for debug output).

=item B<--silent> : Supress all logging output (overrides --verbose).

=item B<--help> : Print a brief help message and exit.

=back

=cut

################################################################################
# a convenience method for displaying usage information & exit with an error by default
sub usage {
  my $message = shift;
  my $exitval = 1;

  if (looks_like_number($message)) {
    $exitval = $message;
    $message = undef;
  }

  pod2usage( -message => $message, -exitval => $exitval );

  # pod2usage should take care of this, but just in case...
  exit $exitval;
}

################################################################################
# parse command line options
my $opt_silent = 0;
my $opt_verbose = 0;
my $opt_help = 0;
my $opt_retry_count = 3;
my $opt_retry_delay = 5;
my $opt_catalog = undef;
my $opt_datadir = undef;
my $opt_download = 1;
my $opt_prune = 0;
my $opt_agent = undef;
my $opt_mapname = '{Primary State}/{Map Name}.pdf';

GetOptions(
  'catalog=s' => \$opt_catalog,
  'datadir=s' => \$opt_datadir,
  'retry=i' => \$opt_retry_count,
  'mapname=s' => \$opt_mapname,
  'download!' => \$opt_download,
  'prune!' => \$opt_prune,
  'silent|q' => \$opt_silent,
  'verbose|v+' => \$opt_verbose,
  'agent=s' => \$opt_agent,
  'help|?' => \$opt_help
) or usage(1);

usage(0) if $opt_help;

usage('Catalog is required') unless defined $opt_catalog;
usage("File not found: $opt_catalog") unless -s $opt_catalog;
usage('Data directory is required') unless defined $opt_datadir;
usage("Directory not found: $opt_datadir") unless -d $opt_datadir;

my $silent = $opt_silent;
my $verbose = ($opt_verbose >= 1) && (not $silent);
my $debug = ($opt_verbose >= 2) && (not $silent);

my $datadir = File::Spec->rel2abs($opt_datadir);
printf("Saving to directory: %s\n", $datadir) unless $silent;

my $catalog = File::Spec->rel2abs($opt_catalog);
printf("Loading catalog: %s\n", $catalog) unless $silent;

debug("Filename format: $opt_mapname", $debug);

################################################################################
# configure the common client for download files
my $client = LWP::UserAgent->new;

defined $opt_agent and $client->agent($opt_agent);
debug('User Agent: ' . $client->agent, $debug);

# track valid files
my %files = { };

################################################################################
# generate the full file path for a given record - the argument is a hashref
sub get_local_path {
  my ($item) = @_;

  my $filename = $opt_mapname;
  while ($filename =~ m/{([^}]+)}/) {
    my $field = $1;

    my $value = $item->{$field};
    $value =~ s/[^A-Za-z0-9_ -]/_/g;

    $filename =~ s/{$field}/$value/g;
  }

  File::Spec->join($datadir, $filename);
}

################################################################################
# determines if the local copy of item is current
sub is_current {
  my ($item) = @_;

  my $pdf_path = get_local_path($item);

  # first, make sure the file exists
  debug("Checking for local file: $pdf_path", $debug);
  return undef unless -f $pdf_path;

  # make sure the size of the local file matches the published item
  my $pdf_len = -s $pdf_path;
  my $item_len = $item->{'Byte Count'};
  debug("Local file size: $pdf_len bytes (expecting $item_len)", $debug);
  return undef unless ($pdf_len eq $item_len);

  # all is well...
  return $pdf_path;
}

################################################################################
# extract the first member of an archive to a specifc filename
sub extract_one {
  my ($zipfile, $tofile) = @_;

  debug("Loading archive: $zipfile", $debug);

  # make necessary directories
  mkpath(dirname($tofile));

  my $zip = Archive::Zip->new($zipfile);
  unless (defined $zip) {
    error('invalid archive file', not $silent);
    return;
  }

  # only process the first entry
  my @members = $zip->members;

  if (scalar(@members) == 0) {
    error('empty archive', not $silent);
    return;
  } elsif (scalar(@members) > 1) {
    error('unexpected entries in archive', not $silent);
    return;
  }

  my $entry = $members[0];

  my $name = $entry->fileName;
  my $full_size = $entry->uncompressedSize;
  debug("Extracting: $name ($full_size bytes)", $debug);

  if ($entry->extractToFileNamed($tofile) != AZ_OK) {
    error('error writing file', not $silent);
    return;
  }

  debug("Wrote: $tofile", $debug);
}

################################################################################
# download a remote file and return the content
sub fetch_data {
  my ($url) = @_;

  debug("Downloading: $url", $debug);

  my $time_start = [gettimeofday];
  my $resp = $client->get($url);
  my $elapsed = tv_interval($time_start);

  debug('HTTP ' . $resp->status_line, $debug);

  if ($resp->is_error) {
    error('download error: ' . $resp->status_line, not $silent);
    return undef;
  }

  my $data = $resp->decoded_content;

  my $dl_length = length($data);
  my $mbps = pretty_bytes($dl_length / $elapsed) . '/s';
  msg("Downloaded $dl_length bytes in $elapsed seconds ($mbps)", $verbose);

  return $data;
}

################################################################################
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch_save {
  my ($url) = @_;

  my $data = fetch_data($url) or return undef;

  # save the full content to a temporary file
  my ($fh, $tmpfile) = tempfile('ustopo_plXXXX', TMPDIR => 1, UNLINK => 1);
  debug("Saving download: $tmpfile", $debug);

  # TODO error checking on I/O

  # assume that the content is binary
  binmode $fh;
  print $fh $data;
  close $fh;

  return $tmpfile;
}

################################################################################
# download a specific item and return the path to the local file
sub download_item {
  my $item = shift;

  my $pdf_path = undef;
  my $attempt = 1;

  do {
    my $name = $item->{'Map Name'} . ', ' . $item->{'Primary State'};
    debug("Downloading map item: $name [$attempt]", $debug);

    $pdf_path = try_download_item($item);
    return $pdf_path if ($pdf_path);

    $attempt = dl_retry_block($attempt);
  } while ($attempt);

  # download failed
  return $pdf_path;
}

################################################################################
# returns the next attempt or false when no more attempts are available
# FIXME this is kind of a hack...  it's really just to make download_item easier
# to read.  instead, this is a bit ugly with unexpected return behavior, IMHO
sub dl_retry_block {
  my $attempt = shift;

  if (++$attempt > $opt_retry_count) {
    return 0;
  }

  if ($opt_retry_delay) {
    error("Download failed, retrying in $opt_retry_delay sec", $debug);
    sleep $opt_retry_delay;

  } else {
    error('Download failed, retrying', $debug);
  }

  return $attempt;
}

################################################################################
sub try_download_item {
  my $item = shift;

  my $pdf_path = get_local_path($item);

  # download the zip file to a temp location
  my $zipfile = fetch_save($item->{'Download GeoPDF'});
  return undef unless (($zipfile) and (-s $zipfile));

  extract_one($zipfile, $pdf_path);
  unlink $zipfile or carp $!;

  # make sure the file exists after extracting
  return undef unless (-f $pdf_path);

  # compare file size to published item size in catalog
  unless (-s $pdf_path == $item->{'Byte Count'}) {
    unlink $pdf_path or carp $!;
    return undef;
  }

  return $pdf_path;
}

################################################################################
# consulted - http://www.perlmonks.org/?node_id=378538
sub pretty_bytes {
  my $bytes = shift;

  # TODO a better way to do this?

  my @units = qw( B KB MB GB TB PB EB ZB YB );
  my $unit = 0;

  my $sign = ($bytes < 0) ? -1 : 1;
  $bytes = abs($bytes);

  while ($bytes > 1024) {
    $bytes /= 1024;
    $unit++;
  }

  sprintf('%.2f %s', $sign*$bytes, $units[$unit]);
}

################################################################################
# pruning function for files that are not valid for the current catalog
sub prune {
  my $path = $File::Find::name;

  # TODO remove empty directories
  return if (-d $path);

  unless (exists($files{$path})) {
    msg("Removing file: $path", $verbose);
    unlink $path or carp $!;
  }
}

################################################################################
## MAIN ENTRY

debug("Parsing catalog file: $opt_catalog", $debug);

my $csv = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') && ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

debug('Reading catalog...', $debug);

while (my $item = $csv->fetch) {
  my $name = $item->{'Map Name'};
  my $state = $item->{'Primary State'};
  my $cell_id = $item->{'Cell ID'};

  printf("Processing map: %s, %s <%s>\n", $name, $state, $cell_id) unless $silent;

  my $local_file = is_current($item);

  if ($local_file) {
    msg("Map is current: $local_file", $verbose);
    $files{$local_file} = 1;

  } elsif ($opt_download) {
    msg("Download required <$cell_id>", $verbose);
    $local_file = download_item($item);

    if ($local_file) {
      $files{$local_file} = 1;
    } else {
      error("Download failed for <$cell_id>", not $silent);
    }

  } else {
    msg("Download skipped <$cell_id>", $verbose);
  }
}

debug('Finished reading catalog.', $debug);

if ($opt_prune) {
  printf("Pruning orphaned files and empty directories...\n") unless $silent;
  finddepth(\&prune, $datadir);
}

__END__

=pod

=head1 DESCRIPTION

B<ustopo.pl> maintains a local repository of maps from the US Topo catalog.  The USGS produces
high-resolution PDF's that contain geospacial extensions for use in mobile applications such
as L<Avenza PDF Maps|https://www.avenzamaps.com>.  Additionally, the USGS makes these maps
available free for public use.  According to the USGS, about 75 maps are added to the catalog
each day.  The entire size of the catalog is approximately 1.5TB.

These maps are also suitable for printing.  They contain multiple layers, including topographic
lines, satellite imagery, road information & landmarks.  For best results, use an application
such as Adobe Acrobat Reader that allows you to configure which layers are visible.

In order to use B<ustopo.pl>, you will need to download the latest CSV catalog.  This catalog
is updated regularly as a zip archive.  This script operates on the C<topomaps_all.csv> file
in that archive.  It will only download current maps from the US Topo series.

The C<--mapname> format string uses fields from the catalog as placeholders.  The default value
is C<{Primary State}/{Map Name}.pdf> which will place the map in a subfolder by state.  Each
placeholder is placed in braces and will be expanded for each map.  For additional fields, read
the C<readme.txt> file included with the catalog.

Download the latest catalog here: L<http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip>

Browse the collection here: L<https://geonames.usgs.gov/pls/topomaps/>

Use in accordance with the terms of the L<USGS|https://www2.usgs.gov/faq/?q=categories/9797/3572>.

=head1 REQUIREMENTS

=over

=item B<Log::Message::Simple> - debug and logging output

=item B<Parse::CSV> - used to parse the catalog file

=item B<Mozilla::CA> - recommended for HTTPS connections

=back

=head1 TODO

=over

=item Automatically download the latest catalog.

=item Save catalog to a local database for improved searching.

=item Specify maximum number of maps to download per session (default to unlimited).

=item Use a PID file.

=item Provide some encapsulation for logical components (items, download attempts, etc).

=back

=cut
