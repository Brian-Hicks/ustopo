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
use File::Find;

use Carp;
use Data::Dumper;
use Log::Message::Simple qw( :STD );

################################################################################

=pod

=head1 OPTIONS

=over

=item B<--data=dir> : Directory location to save maps when downloading.

=item B<--catalog=file> : CSV catalog file from the USGS.

=item B<--download> : Download all new map items (default behavior).

=item B<--download=max> : Download up to max items (0 = no limit).

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
# parse command line options
my $opt_silent = 0;
my $opt_verbose = 0;
my $opt_help = 0;

my $opt_catalog = undef;
my $opt_datadir = undef;

my $opt_download = 0;
my $opt_prune = 0;

my $opt_retry_count = 3;
my $opt_retry_delay = 5;

my $opt_agent = undef;
my $opt_mapname = '{State}/{Name}.pdf';

GetOptions(
  'datadir=s' => \$opt_datadir,
  'catalog=s' => \$opt_catalog,
  'retry=i' => \$opt_retry_count,
  'mapname=s' => \$opt_mapname,
  'download:n' => \$opt_download,
  'no-download' => sub { $opt_download = -1 },
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

debug("Filename format: $opt_mapname", $debug);
debug("Download limit: $opt_download", $debug);

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

my %files = ( );

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
package ObjectBase;

use Log::Message::Simple qw( :STD );

#-------------------------------------------------------------------------------
sub get {
  my ($self, $key) = @_;

  $self->{$key};
}

#-------------------------------------------------------------------------------
sub set {
  my ($self, $key, $value) = @_;

  $self->{$key} = $value;
}

#-------------------------------------------------------------------------------
sub get_set {
  my ($self, $key, $value) = @_;

  if ($value) {
    $self->set($key, $value);
  }

  $self->get($key);
}

################################################################################
package CatalogItem;

use parent -norequire, 'ObjectBase';

use File::Spec;
use Log::Message::Simple qw( :STD );

#-------------------------------------------------------------------------------
sub new {
  my ($proto, $id) = @_;

  my $self = {
    ID => $id
  };

  bless($self);
  return $self;
}

#-------------------------------------------------------------------------------
# a unique identifier for this map file
sub id {
  my ($self) = @_;
  $self->get('ID');
}

#-------------------------------------------------------------------------------
# the URL for downloading the map file
sub url {
  my ($self, $value) = @_;
  $self->get_set('URL', $value);
}

#-------------------------------------------------------------------------------
# the size of the map file in bytes
sub file_size {
  my ($self, $value) = @_;
  $self->get_set('FileSize', $value);
}

#-------------------------------------------------------------------------------
# the name of this map
sub name {
  my ($self, $value) = @_;
  $self->get_set('Name', $value);
}

#-------------------------------------------------------------------------------
# the title of this map
sub title {
  my ($self) = @_;

  sprintf('USGS US Topo map for %s, %s %d', $self->name, $self->state, $self->year);
}

#-------------------------------------------------------------------------------
# the primary state this map covers
sub state {
  my ($self, $value) = @_;
  $self->get_set('State', $value);
}

#-------------------------------------------------------------------------------
# the year imprinted on this map
sub year {
  my ($self, $value) = @_;
  $self->get_set('Year', $value);
}

#-------------------------------------------------------------------------------
# generate the full file path for the current item
sub local_path {
  my ($self) = @_;

  my $filename = $opt_mapname;
  while ($filename =~ m/{([^}]+)}/) {
    my $field = $1;

    my $value = $self->{$field};
    $value =~ s/[^A-Za-z0-9_ -]/_/g;

    $filename =~ s/{$field}/$value/g;
  }

  File::Spec->join($datadir, $filename);
}

#-------------------------------------------------------------------------------
# determines if the local copy of item is current, returns the local path if so
sub is_current {
  my ($self, $item) = @_;

  my $pdf_path = $self->local_path;

  # first, make sure the file exists
  debug("Checking for local file: $pdf_path", $debug);
  return undef unless -f $pdf_path;

  # make sure the size of the local file matches the published item
  my $pdf_len = -s $pdf_path;
  my $pub_len = $self->file_size;

  debug("Local file size: $pdf_len bytes (expecting $pub_len)", $debug);
  return undef unless ($pdf_len eq $pub_len);

  # all is well...
  return $pdf_path;
}

#-------------------------------------------------------------------------------
sub from_csv {
  my $row = shift;

  my $id = $row->{'Cell ID'};
  debug("Parsing CatalogItem <$id>", $debug);

  my $item = CatalogItem->new($id);
  $item->name($row->{'Map Name'});
  $item->state($row->{'Primary State'});
  $item->url($row->{'Download GeoPDF'});
  $item->file_size($row->{'Byte Count'});
  $item->year($row->{'Date On Map'});

  $item;
}

################################################################################
package DownloadClient;

use parent -norequire, 'ObjectBase';

use Time::HiRes qw( gettimeofday tv_interval );
use File::Temp qw( tempfile );
use Log::Message::Simple qw( :STD );
use LWP::UserAgent;

debug("libwww-perl-$LWP::VERSION", $debug);

#-------------------------------------------------------------------------------
sub new {
  my ($proto) = @_;

  my $ua = LWP::UserAgent->new;

  defined $opt_agent and $ua->agent($opt_agent);
  debug('User Agent: ' . $ua->agent, $debug);

  my $self = {
    _ua => $ua
  };

  bless($self);
  return $self;
}

#-------------------------------------------------------------------------------
# download a remote file and return the content
sub fetch_data {
  my ($self, $url) = @_;

  my $client = $self->{_ua};
  debug("Downloading URL: $url", $debug);

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
  my $mbps = ::pretty_bytes($dl_length / $elapsed) . '/s';
  msg("Downloaded $dl_length bytes in $elapsed seconds ($mbps)", $verbose);

  return $data;
}

#-------------------------------------------------------------------------------
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch_save {
  my ($self, $url) = @_;

  my $data = $self->fetch_data($url) or return undef;

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
package DownloadManager;

use parent -norequire, 'ObjectBase';

use File::Path qw( mkpath );
use File::Basename;
use Archive::Zip qw( :ERROR_CODES );
use Log::Message::Simple qw( :STD );

#-------------------------------------------------------------------------------
sub new {
  my ($proto) = @_;

  my $client = DownloadClient->new;

  my $self = {
    _client => $client,
    _attempts => undef,
    TotalBytes => 0,
    DownloadCount => 0
  };

  bless($self);
  return $self;
}

#-------------------------------------------------------------------------------
# returns the number of items that have been succesfully downloaded
sub count {
  my ($self, $value) = @_;
  $self->get_set('DownloadCount', $value);
}

#-------------------------------------------------------------------------------
# determines if the download manager is able to download items
sub enabled {
  my ($self) = @_;

  ($opt_download eq 0) or ($self->count lt $opt_download);
}

#-------------------------------------------------------------------------------
# download a specific item and return the path to the local file
sub download {
  my ($self, $item) = @_;

  my $pdf_path = undef;
  my $attempt = 1;

  $self->reset();

  do {
    my $title = $item->title;
    debug("Downloading item: $title [$attempt]", $debug);

    $pdf_path = $self->download_item($item);
    return $pdf_path if ($pdf_path);

    $attempt++;
  } while ($self->retry);

  # download failed, else we would have returned in the loop

  error('Download failed for <' . $item->id . '>', not $silent);

  return undef;
}

#-------------------------------------------------------------------------------
# reset the DownloadManager for the next download - typically used internally
sub reset {
  my ($self) = @_;

  if ($opt_retry_count) {
    $self->{_attempts} = $opt_retry_count;
  }
}

#-------------------------------------------------------------------------------
# prepare for the next download if any retries are left, else return 0
sub retry {
  my ($self) = @_;

  # XXX should we allow infinite retries here?

  return 0 unless (--$self->{_attempts});

  if ($opt_retry_delay) {
    error("Download failed, retrying in $opt_retry_delay sec", $debug);
    sleep $opt_retry_delay;

  } else {
    error('Download failed, retrying', $debug);
  }

  $self->{_attempts};
}

#-------------------------------------------------------------------------------
sub download_item {
  my ($self, $item) = @_;

  my $client = $self->{_client};
  my $pdf_path = $item->local_path;

  # download the zip file to a temp location
  my $zipfile = $client->fetch_save($item->url);
  $self->{TotalBytes} += -s $zipfile;
  return undef unless (($zipfile) and (-s $zipfile));

  extract_one($zipfile, $pdf_path);
  unlink $zipfile or carp $!;

  # make sure the file exists after extracting
  return undef unless (-f $pdf_path);

  # compare file size to expected item size
  unless (-s $pdf_path eq $item->file_size) {
    unlink $pdf_path or carp $!;
    return undef;
  }

  # successful download
  $self->{DownloadCount}++;

  return $pdf_path;
}

#-------------------------------------------------------------------------------
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
package main;

my $catalog = File::Spec->rel2abs($opt_catalog);
printf("Loading catalog: %s\n", $catalog) unless $silent;

debug("Parsing catalog file: $opt_catalog", $debug);

my $csv = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') && ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

my $dl = DownloadManager->new;

debug('Reading catalog...', $debug);

while (my $row = $csv->fetch) {
  my $item = CatalogItem::from_csv($row);
  my $id = $item->id;

  printf("Processing: %s <%s>\n", $item->title, $id) unless $silent;

  my $local_file = $item->is_current();

  if ($local_file) {
    msg("Map is current: $local_file", $verbose);

  } elsif ($dl->enabled) {
    msg("Download required <$id>", $verbose);
    $local_file = $dl->download($item);

  } else {
    msg("Download skipped <$id>", $verbose);
  }

  # track all files
  if ($local_file) {
    $files{$local_file} = 1;
  }
}

debug('Finished reading catalog.', $debug);

my $dl_count = $dl->count;
if (($dl_count) and (not $silent)) {
  printf("Downloaded %d item%s", $dl_count, ($dl_count eq 1) ? '' : 's');
  printf(" (%s).\n", pretty_bytes($dl->{TotalBytes}));
}

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

To control the number of downloads, use the C<--download=max> option.  Specifying a C<max> value
of C<0> will enable unlimited downloads.  Otherwise, the program will only download up to the
given value.  A negative value will disable all downloads (identical to C<--no-download>).  Note
that failed downloads do not count against the maximum.

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

=item Use a PID file.

=item Load config options from file.

=item Improve logging (Log4Perl?).

=back

=cut
