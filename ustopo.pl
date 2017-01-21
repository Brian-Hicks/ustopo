#!/usr/bin/perl -w

=pod

=head1 NAME

ustopo.pl -- Maintains an offline catalog of US Topo maps.

=head1 SYNOPSIS

  ustopo.pl --data=dir [options]

=cut

################################################################################

use strict;

use Getopt::Long qw( :config bundling );
use Scalar::Util qw( looks_like_number );
use Pod::Usage;

use File::Spec;
use File::Path qw( mkpath );
use File::Temp qw( tempfile );
use File::Basename;

use DBI;
use LWP::UserAgent;
use Archive::Zip qw( :ERROR_CODES );
use Time::HiRes qw( gettimeofday tv_interval );

use Log::Message::Simple qw( :STD :CARP );
use Data::Dumper;

################################################################################

=pod

=head1 OPTIONS

=over

=item B<--data=dir> : Directory location to save maps when downloading.

=item B<--import=file> : Import the given catalog into the database.

=item B<--agent=string> : Set the User Agent string for the download client.

=item B<--update> : Update the local database (default behavior).

=item B<--no-update> : Do not update local database (often used with --import).

=item B<--mapname=string> : Specify the format string for map filenames.

=item B<--agent=string> : Set the User Agent string for the download client.

=item B<--dryrun> : Don't actually download or extract files.

=item B<--verbose> : Display extra logging output for debugging.

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
my $opt_datadir = undef;
my $opt_agent = undef;
my $opt_import = undef;
my $opt_update = 1;
my $opt_dryrun = 0;
my $opt_mapname = '{State}/{MapName}.pdf';

GetOptions(
  'datadir|D=s' => \$opt_datadir,
  'import|C=s' => \$opt_import,
  'update!' => \$opt_update,
  'mapname=s' => \$opt_mapname,
  'dryrun|N' => \$opt_dryrun,
  'silent|s' => \$opt_silent,
  'verbose|v' => \$opt_verbose,
  'agent=s' => \$opt_agent,
  'help|?' => \$opt_help
) or usage(1);

usage(0) if $opt_help;

usage('Data directory is required') unless defined $opt_datadir;
usage("Directory not found: $opt_datadir") unless -d $opt_datadir;

my $silent = $opt_silent;
my $debug = ($opt_verbose) && (not $opt_silent);

my $datadir = File::Spec->rel2abs($opt_datadir);
msg("Using data directory: $datadir", not $silent);

debug("Filename format: $opt_mapname", $debug);

################################################################################
# configure the common client for download files
my $client = LWP::UserAgent->new;

defined $opt_agent and $client->agent($opt_agent);
debug('User Agent: ' . $client->agent, $debug);

################################################################################
# initialize the database connection
my $db_file = File::Spec->join($datadir, 'index.db');

debug("Connecting to database $db_file", $debug);
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef);

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
  debug("Filename: $filename", $debug);

  my $abs_datadir = File::Spec->rel2abs($datadir);
  File::Spec->join($abs_datadir, $filename);
}

################################################################################
# determines if the local copy of item is current
sub is_current {
  my ($item) = @_;

  my $pdf_path = $item->{LocalFile};
  unless (defined $pdf_path) {
    debug("LocalFile not specified; using default location.", $debug);
    $pdf_path = get_local_path($item);
  }

  # first, make sure the file exists
  debug("Checking for local file: $pdf_path", $debug);
  return undef unless -f $pdf_path;

  # make sure the size of the local file matches the published item
  my $item_len = $item->{FileSize};
  return undef unless ($item_len);

  my $pdf_len = -s $pdf_path;
  debug("Local file size: $pdf_len bytes (expecting $item_len)", $debug);
  return undef unless ($pdf_len eq $item_len);

  # all is well...
  return $pdf_path;
}

################################################################################
# extract the first member of an archive to a specifc filename
sub extract_to {
  my ($zipfile, $tofile) = @_;

  debug("Loading archive: $zipfile", $debug);

  # make necessary directories
  my $dirname = dirname($tofile);
  mkpath($dirname);

  my $zip = Archive::Zip->new($zipfile);
  croak 'error loading archive' unless defined $zip;

  # only process the first entry
  my @members = $zip->members;
  if (scalar(@members) == 0) {
    carp 'empty archive';
    return;
  } elsif (scalar(@members) > 1) {
    carp 'unexpected entries in archive';
    return;
  }

  my $entry = $members[0];

  my $name = $entry->fileName;
  my $full_size = $entry->uncompressedSize;
  debug("Extracting: $name ($full_size bytes)", $debug);

  if ($entry->extractToFileNamed($tofile) != AZ_OK) {
    croak 'error writing file';
  }

  debug("Wrote: $tofile", $debug);
}

################################################################################
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch {
  my ($url) = @_;

  debug("Downloading: $url", $debug);

  my $time_start = [gettimeofday];
  my $resp = $client->get($url);
  my $elapsed = tv_interval($time_start);

  debug('HTTP ' . $resp->status_line, $debug);

  # TODO maybe better to go to the next file?  especially for 404...
  if ($resp->is_error) {
    croak 'download error: ' . $resp->status_line;
  }

  my $dl_length = length($resp->decoded_content);
  my $mbps = ($dl_length / $elapsed) / (1024*1024);
  debug("Downloaded $dl_length bytes in $elapsed seconds ($mbps MB/s)", $debug);

  # save the zipfile to a temporary file
  my ($fh, $tmpfile) = tempfile('ustopo_plXXXX', TMPDIR => 1, UNLINK => 1);
  debug("Saving download: $tmpfile", $debug);

  binmode $fh;
  print $fh $resp->decoded_content;
  close $fh;

  return $tmpfile;
}

################################################################################
# download a specific item and return the path to the local file
sub download_item {
  return if $opt_dryrun;

  my ($item) = @_;

  my $pdf_path = get_local_path($item);

  # download the zip file to a temp location
  my $zipfile = fetch($item->{GeoPDF});
  croak 'download error' unless -s $zipfile;

  extract_to($zipfile, $pdf_path);

  # compare file size to published item size in catalog
  if ($item->{FileSize}) {
    croak 'size mismatch' unless (-s $pdf_path eq $item->{FileSize});
  }

  unlink $zipfile or carp $!;
  return $pdf_path;
}

################################################################################
sub update_local_file {
  my ($item) = @_;

  my $cell_id = $item->{CID};
  my $local_file = is_current($item);

  if ($local_file) {
    debug("Map is up to date: $local_file", $debug);

  } else {
    debug("Download required <$cell_id>", $debug);
    $local_file = download_item($item)
  }

  return if $opt_dryrun;

  my $file_size = ($local_file) ? -s $local_file : 0;

  # $local_file should now be up to date
  $dbh->do('UPDATE maps SET LocalFile=?, FileSize=? WHERE ItemID=?;', undef,
           $local_file, $file_size, $item->{ItemID});
}

################################################################################
sub update_metadata {
  my ($item) = @_;

  # TODO update from local file or geo_xml?
}

################################################################################
sub update_database {
}

################################################################################
sub import_csv {
  my ($csv_file) = @_;
}

################################################################################
sub db_maintenance {
  # process all map items in database
  my $sth = $dbh->prepare('SELECT * FROM maps;') or die;
  $sth->execute();

  while (my $row = $sth->fetchrow_hashref) {
    my $name = $row->{MapName};
    my $state = $row->{State};
    my $cell_id = $row->{CID};

    msg("Processing map: $name, $state <$cell_id>", not $silent);

    $dbh->do('BEGIN TRANSACTION;');

    update_local_file($row);
    update_metadata($row);
    # TODO thumbnail?

    $dbh->do('COMMIT;');
  }
}

################################################################################
## MAIN ENTRY

msg("Saving to directory: $datadir", not $silent);

update_database() if $opt_update;
import_csv($opt_import) if $opt_import;
db_maintenance();

# TODO remove extra files in $datadir

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

By default, C<ustopo.pl> will perform regular maintenance on the catalog.  This includes updating
the catalog from ScienceBase, downloading new or modified items and deleted old or expired
records.  Other operations may be explicitly called by passing the appropriate command line
options.

The C<--mapname> format string uses fields from the database as placeholders.  The default value
is C<{State}/{MapName}.pdf> which will place the map in a subfolder by state.  Each placeholder
is placed in braces and will be expanded for each map.  For additional fields, see the database
schema for column names.

Download the latest catalog here: L<http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip>

Browse the collection here: L<https://geonames.usgs.gov/pls/topomaps/>

Download a CSV version of the catalog (suitable for importing) here:
L<http://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip>

Use in accordance with the terms of the L<USGS|https://www2.usgs.gov/faq/?q=categories/9797/3572>.

=head1 REQUIREMENTS

=over

=item B<Log::Message::Simple> - debug and logging output

=item B<Parse::CSV> - used to parse the catalog file

=item B<Mozilla::CA> - recommended for HTTPS connections

=back

=head1 TODO

=over

=item Generate browseable HTML file offline of maps.

=item Improve check for a current file using PDF metadata.

=item Insert GeoXML metadata into PDF XMP stream.

=item Retry failed downloads (default to 3).

=item Specify maximum number of maps to download per session (default to unlimited).

=item Use a lock file.

=back

=cut
