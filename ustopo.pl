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

use Data::Dumper;
use Log::Log4perl qw( :easy );

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

=item B<--help> : Print a brief help message and exit.

=back

=cut

################################################################################
# parse command line options
my $opt_help = 0;

my $opt_config = undef;

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
  'config=s' => \$opt_config,
  'retry=i' => \$opt_retry_count,
  'mapname=s' => \$opt_mapname,
  'download:n' => \$opt_download,
  'no-download' => sub { $opt_download = -1 },
  'prune!' => \$opt_prune,
  'agent=s' => \$opt_agent,
  'help|?' => \$opt_help
) or usage(1);

usage(0) if $opt_help;

usage('Catalog is required') unless defined $opt_catalog;
usage("Catalog not found: $opt_catalog") unless -f $opt_catalog;
usage('Data directory is required') unless defined $opt_datadir;
usage("Directory not found: $opt_datadir") unless -d $opt_datadir;
usage("Config file not found: $opt_config") if (($opt_config) && (not -f $opt_catalog));

if ($opt_config) {
  Log::Log4perl->init($opt_config);
} else {
  Log::Log4perl->easy_init($ERROR);
}

my $logger = Log::Log4perl->get_logger('ustopo');

$logger->trace('Application Started');
$logger->debug('Configuration file: ', File::Spec->rel2abs($opt_config));

$logger->debug('Filename format: ', $opt_mapname);
$logger->debug('Download limit: ', $opt_download);

my $datadir = File::Spec->rel2abs($opt_datadir);
printf("Saving to directory: %s\n", $datadir);

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

  $logger->debug('Considering: ', $path);

  # TODO remove empty directories
  return if (-d $path);

  unless (exists($files{$path})) {
    $logger->info('Removing file: ', $path);
    unlink $path or $logger->logwarn($!);
  }
}

################################################################################
package ObjectBase;

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

#-------------------------------------------------------------------------------
sub new {
  my ($proto, $id) = @_;

  $logger->trace('New CatalogItem: ', $id);

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

  sprintf('USTopo map for %s, %s %d', $self->name, $self->state, $self->year);
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

  $logger->trace('local_path: ', $filename);
  File::Spec->join($datadir, $filename);
}

#-------------------------------------------------------------------------------
# determines if the local copy of item is current, returns the local path if so
sub is_current {
  my ($self, $item) = @_;

  my $pdf_path = $self->local_path;

  # first, make sure the file exists
  $logger->debug('Checking for local file: ', $pdf_path);
  return undef unless -f $pdf_path;

  # make sure the size of the local file matches the published item
  my $pdf_len = -s $pdf_path;
  my $pub_len = $self->file_size;

  $logger->debug("Actual file size: $pdf_len bytes ($pub_len expected)");
  return undef unless ($pdf_len == $pub_len);

  # all is well...
  return $pdf_path;
}

#-------------------------------------------------------------------------------
sub from_csv {
  my $row = shift;

  my $id = $row->{'Cell ID'};
  $logger->trace("Parsing CatalogItem <$id>");

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
use LWP::UserAgent;

$logger->debug('libwww-perl-', $LWP::VERSION);

#-------------------------------------------------------------------------------
sub new {
  my ($proto) = @_;

  my $ua = LWP::UserAgent->new;

  defined $opt_agent and $ua->agent($opt_agent);
  $logger->trace('User Agent: ', $ua->agent);

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

  $logger->debug('Downloading URL: ', $url);

  my $client = $self->{_ua};

  my $time_start = [gettimeofday];
  my $resp = $client->get($url);
  my $elapsed = tv_interval($time_start);

  $logger->trace('HTTP ', $resp->status_line);

  if ($resp->is_error) {
    $logger->error('download error: ', $resp->status_line);
    return undef;
  }

  my $data = $resp->decoded_content;

  if ($logger->is_info) {
    my $dl_length = length($data);
    my $mbps = ::pretty_bytes($dl_length / $elapsed) . '/s';
    $logger->info("Downloaded $dl_length bytes in $elapsed seconds ($mbps)");
  }

  return $data;
}

#-------------------------------------------------------------------------------
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch_save {
  my ($self, $url) = @_;

  my $data = $self->fetch_data($url) or return undef;

  # save the full content to a temporary file
  my ($fh, $tmpfile) = tempfile('ustopo_plXXXX', TMPDIR => 1, UNLINK => 1);
  $logger->debug('Saving download: ', $tmpfile);

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

  my $remaining = 0;

  if ($opt_download == 0) {
    $logger->debug('Remaining downloads: no limit');
    $remaining = 1;

  } elsif ($self->count < $opt_download) {
    $remaining = $opt_download - $self->count;
    $logger->debug('Remaining downloads: ', $remaining);

  } else {
    $remaining = 0;
    $logger->debug('Remaining downloads: 0');
  }

  $logger->trace('DownloadManager enabled: ', ($remaining) ? 'yes' : 'no');

  return $remaining;
}

#-------------------------------------------------------------------------------
# download a specific item and return the path to the local file
sub download {
  my ($self, $item) = @_;

  $logger->trace('Current download count: ', $self->count);

  my $pdf_path = undef;
  my $attempt = 1;

  $self->reset();

  do {
    $logger->debug('Downloading item: ', $item->title, " [$attempt]");

    $pdf_path = $self->download_item($item);
    return $pdf_path if ($pdf_path);

    $attempt++;
  } while ($self->retry);

  # download failed, else we would have returned in the loop

  $logger->error('Download failed for <', $item->id, '>');

  return undef;
}

#-------------------------------------------------------------------------------
# reset the DownloadManager for the next download - typically used internally
sub reset {
  my ($self) = @_;

  $logger->trace('Reset DownloadManager - retry:', $opt_retry_count);

  if ($opt_retry_count) {
    $self->{_attempts} = $opt_retry_count;
  }
}

#-------------------------------------------------------------------------------
# prepare for the next download if any retries are left, else return 0
sub retry {
  my ($self) = @_;

  $logger->trace('Retry: ', $self->{_attempts});

  # XXX should we allow infinite retries here?

  return 0 unless ($self->{_attempts});

  if ($opt_retry_delay) {
    $logger->error('Download failed, retrying in ', $opt_retry_delay, ' sec');
    sleep $opt_retry_delay;

  } else {
    $logger->error('Download failed, retrying');
  }

  $self->{_attempts}--;
}

#-------------------------------------------------------------------------------
sub download_item {
  my ($self, $item) = @_;

  my $client = $self->{_client};
  my $pdf_path = $item->local_path;

  # download the zip file to a temp location
  my $zipfile = $client->fetch_save($item->url);
  $self->{TotalBytes} += -s $zipfile;
  return undef unless (($zipfile) && (-s $zipfile));

  extract_one($zipfile, $pdf_path);
  unlink $zipfile or $logger->logwarn($!);

  # make sure the file exists after extracting
  return undef unless (-f $pdf_path);

  # compare file size to expected item size
  unless (-s $pdf_path == $item->file_size) {
    unlink $pdf_path or $logger->logwarn($!);
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

  $logger->trace('Loading archive: ', $zipfile);

  # make necessary directories
  mkpath(dirname($tofile));

  my $zip = Archive::Zip->new($zipfile);
  unless (defined $zip) {
    $logger->error('invalid archive file');
    return;
  }

  # only process the first entry
  my @members = $zip->members;

  if (scalar(@members) == 0) {
    $logger->error('empty archive');
    return;
  } elsif (scalar(@members) > 1) {
    $logger->error('unexpected entries in archive');
    return;
  }

  my $entry = $members[0];

  my $name = $entry->fileName;
  my $full_size = $entry->uncompressedSize;
  $logger->debug('Extracting: ', $entry->fileName, " ($full_size bytes)");

  if ($entry->extractToFileNamed($tofile) != AZ_OK) {
    $logger->error('error writing file');
    return;
  }

  $logger->debug('Wrote: ', $tofile);
}

################################################################################
package main;

my $catalog = File::Spec->rel2abs($opt_catalog);
printf("Loading catalog: %s\n", $catalog);

$logger->debug('Parsing catalog file: ', $opt_catalog);

my $csv = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') && ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

my $dl = DownloadManager->new;

$logger->debug('Reading catalog...');

while (my $row = $csv->fetch) {
  my $item = CatalogItem::from_csv($row);
  my $id = $item->id;

  $logger->info('Processing: ', $item->title, " <$id>");
  printf("Processing: %s <%s>\n", $item->title, $id);

  my $local_file = $item->is_current();

  if ($local_file) {
    $logger->info('Map is current: ', $local_file);

  } elsif ($dl->enabled) {
    $logger->info('Download required <', $item->id, '>');
    $local_file = $dl->download($item);

  } else {
    $logger->info('Download skipped <', $item->id, '>');
  }

  # track all files
  if ($local_file) {
    $files{$local_file} = 1;
  }
}

$logger->debug('Finished reading catalog.');

if ($dl->count) {
  printf("Downloaded %d item%s", $dl->count, ($dl->count == 1) ? '' : 's');
  printf(" (%s)\n", pretty_bytes($dl->{TotalBytes}));
}

if ($opt_prune) {
  printf("Pruning orphaned files and empty directories...\n");
  finddepth(\&prune, $datadir);
}

$logger->trace('Application Finished');

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

=item B<Log::Log4Perl> - debug and logging output

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
