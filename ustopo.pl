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
use File::Find;

use JSON;
use DBI;
use DateTime;
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

=item B<--agent=string> : Set the User Agent string for the download client.

=item B<--mapname=string> : Specify the format string for map filenames.

=item B<--retry=num> : Number of retries for failed downloads.

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
my $opt_retry = 3;
my $opt_mapname = '{State}/{MapName}.pdf';
my $opt_sb_max_items = 10;

GetOptions(
  'datadir|D=s' => \$opt_datadir,
  'retry=i' => \$opt_retry,
  'mapname=s' => \$opt_mapname,
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
msg("Saving to directory: $datadir", not $silent);

debug("Filename format: $opt_mapname", $debug);

my $sb_catalog = "https://www.sciencebase.gov/catalog";

################################################################################
# configure the common client for download files
my $client = LWP::UserAgent->new;

defined $opt_agent and $client->agent($opt_agent);
debug('User Agent: ' . $client->agent, $debug);

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

  File::Spec->join($datadir, $filename);
}

################################################################################
# determines if the local copy of item is current
sub is_current {
  my ($item) = @_;

  my $pdf_path = $item->{LocalFilePath};
  unless (defined $pdf_path) {
    debug("LocalFilePath not specified; using default location.", $debug);
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
# download a file and save it locally - NOTE file will be deleted on exit
sub fetch_data {
  my ($url) = @_;

  debug("Downloading: $url", $debug);

  my $time_start = [gettimeofday];
  my $resp = $client->get($url);
  my $elapsed = tv_interval($time_start);

  debug('HTTP ' . $resp->status_line, $debug);

  # TODO maybe better to go to the next file?  especially for 404...
  if ($resp->is_error) {
    error('download error: ' . $resp->status_line, not $silent);
    return undef;
  }

  my $data = $resp->decoded_content;

  my $dl_length = length($data);
  my $mbps = ($dl_length / $elapsed) / (1024*1024);
  debug("Downloaded $dl_length bytes in $elapsed seconds ($mbps MB/s)", $debug);

  return $data;
}

################################################################################
# download a file and save it locally, if no path is given, a temp file will be
# created -- NOTE temp files will be deleted on exit
sub fetch_save {
  my ($url, $path) = @_;

  # TODO mkpath(dirname($tofile));

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

  while (($attempt <= $opt_retry) && (not defined $pdf_path)) {
    my $name = $item->{'Map Name'} . ', ' . $item->{'Primary State'};
    debug("Downloading map item: $name [$attempt]", $debug);

    $pdf_path = try_download_item($item);
    $attempt++;
  }

  return $pdf_path;
}

################################################################################
sub try_download_item {
  my $item = shift;

  my $pdf_path = get_local_path($item);
  fetch_save($item->{GeoPDF_URL}, $pdf_path);

  # compare file size to published item size in catalog
  unless (-s $pdf_path eq $item->{FileSize}) {
    unlink $pdf_path or carp $!;
    error('download size mismatch', not $silent);
    return undef;
  }

  return $pdf_path;
}

################################################################################
# update the internal catalog from ScienceBase
sub sb_update_catalog {
  my $sb_ustopo_id = '4f554236e4b018de15819c85';

  debug('Downloading ScienceBase catalog', $debug);

  my $json_raw = fetch_data("$sb_catalog/items?parentId=$sb_ustopo_id&max=$opt_sb_max_items&format=json");
  my $json = decode_json($json_raw);

  sb_process_items($json);

  # TODO wrap updates in a transaction
  # TODO follow nextlink and do it again...
}

################################################################################
sub sb_process_items {
  my ($json) = @_;

  my $item_count = 0;

  foreach my $item (@{ $json->{'items'} }) {
    my $sbid = $item->{'id'};
    debug("Processing catalog entry: $sbid", $debug);
    sb_import_item($sbid) and $item_count++;
  }

  return $item_count;
}

################################################################################
# update the internal catalog from ScienceBase
sub sb_import_item {
  my ($sbid) = @_;

  my $json_raw = fetch_data("$sb_catalog/item/$sbid?format=json");
  my $json = decode_json($json_raw);

  # assert download sbid == requested sbid
  unless($sbid eq $json->{id}) {
    error('Unexpected item in download: ' . $json->{id});
    return undef;
  }

  sb_process_item($json);
}

################################################################################
# update the internal catalog from ScienceBase
sub sb_process_item {
  my ($json) = @_;

  my $sbid = $json->{id};

  my $title = $json->{title};
  msg("Processing map: $title", not $silent);

  # XXX the CSV catalog provides more robust metadata than ScienceBase
  # this is a bit of a hack, but the only way to get the info we want...
  my ($name, $state) = $title =~ m/USGS US Topo.*for\s+(.+),\s+(..)/;

  my ($date_grp) = grep { $_->{type} eq 'Publication' } @{ $json->{dates} };
  my $pub_date = $date_grp->{dateString};
  my ($year) = $pub_date =~ m/([0-9]+)-([0-9]+)-([0-9]+)/;

  my ($dl_grp) = grep { $_->{type} eq 'download' } @{ $json->{webLinks} };

  my $pdf_link = $dl_grp->{uri};
  my $pdf_size = $dl_grp->{length};

  # fail unless we have all metadata
  unless ($name and $state and $year and $pdf_link) {
    error("Invalid metadata for item $sbid", not $silent);
    return undef;
  }

  debug("Found map item: $name, $state [$year]", $debug);

  # if the item already exists, we need to verify the metadata
  my $item = db_get_item($sbid);
  if ($item) {

    # TODO compare values

  } else {
    $item = db_insert_item($sbid, {
      MapName => $name,
      MapYear => $year,
      PubDate => $pub_date,
      State => $state,
      GeoPDF_URL => $pdf_link,
      FileSize => $pdf_size
    });
  }

  return $item;
}

################################################################################
sub db_migrate {
  my $db_version = db_pragma('user_version');
  debug("Current database version: $db_version", $debug);

  db_transaction(\&db_schema_version_1) unless $db_version ge 1;
  #db_transaction(\&db_schema_version_2) unless $db_version ge 2;
}

################################################################################
sub db_schema_version_1 {
  debug('Applying schema version 1 - initial maps table', $debug);

  $dbh->do(qq{
    CREATE TABLE "maps" (
      `SBID` INTEGER NOT NULL UNIQUE,
      `MapName` TEXT NOT NULL,
      `MapYear` INTEGER,
      `PubDate` INTEGER,
      `State` TEXT NOT NULL,
      `GeoPDF_URL` TEXT NOT NULL,
      `FileSize` INTEGER,
      `LocalFilePath` TEXT UNIQUE
    );
  });

  db_pragma('user_version', 1);
}

################################################################################
sub db_schema_version_2 {
  debug('Applying schema version 2 - update triggers', $debug);

  $dbh->do('ALTER TABLE maps ADD COLUMN CreatedOn TEXT;');
  $dbh->do('ALTER TABLE maps ADD COLUMN LastUpdated TEXT;');

  $dbh->do(qq{
    CREATE TRIGGER created_on INSERT ON maps
    BEGIN
      UPDATE maps SET LastUpdated=CreatedOn WHERE SBID=old.SBID;
    END;
  });

  $dbh->do(qq{
    CREATE TRIGGER last_updated UPDATE ON maps
    BEGIN
      UPDATE maps SET LastUpdated=CURRENT_TIMESTAMP WHERE SBID=old.SBID;
    END;
  });

  db_pragma('user_version', 2);
}

################################################################################
sub db_transaction {
  my $func = shift;

  $dbh->do('BEGIN TRANSACTION;');

  $func->();

  $dbh->do('COMMIT;');
}

################################################################################
sub db_pragma {
  my $pragma = shift;
  my $value = shift;

  if (defined $value) {
    $dbh->do("PRAGMA $pragma=$value;");
  } else {
    my $sth = $dbh->prepare("PRAGMA $pragma;");
    $sth->execute();
    $value = ($sth->fetchrow_array())[0];
  }

  $value;
}

################################################################################
sub db_get_item {
  my $sbid = shift;

  my $sql = "SELECT * FROM maps WHERE SBID=? LIMIT 1;";
  debug("> $sql", $debug);

  my $sth = $dbh->prepare($sql) or die;
  $sth->execute($sbid);

  my $item = $sth->fetchrow_hashref();

  if ($item) {
    debug('Found record: ' . $item->{SBID}, $debug);
  } else {
    debug("No records found.", $debug);
  }

  return $item;
}

################################################################################
sub db_insert_item {
  my $sbid = shift;
  my $params = shift;

  my @names = keys %{ $params };
  my @values = values %{ $params };

  # SBID will be last in the placeholders
  push @names, 'SBID';
  push @values, $sbid;

  my $columns = join(', ', @names);
  my $placeholders = join(', ', map { '?' } @values);

  my $sql = "INSERT INTO maps ($columns) VALUES ($placeholders);";

  debug("> $sql", $debug);
  debug('(' . join(', ', @values) . ')', $debug);

  my $sth = $dbh->prepare($sql) or die;
  $sth->execute(@values);
}

################################################################################
sub db_update_item {
  my $sbid = shift;
  my $params = shift;

  my @names = map { "$_=?" } keys %{ $params };
  my @values = values %{ $params };

  # SBID will be last in the placeholders
  push @values, $sbid;

  my $fields = join(', ', @names);
  my $sql = "UPDATE maps SET $fields WHERE SBID=?;";

  # it would be nice just to print the expanded SQL statement...
  debug("> $sql", $debug);
  debug('(' . join(', ', @values) . ')', $debug);

  return $dbh->do($sql, undef, @values);
}

################################################################################
sub db_update_all {
  # process all map items in database
  my $sth = $dbh->prepare('SELECT * FROM maps;') or die;
  $sth->execute();

  while (my $row = $sth->fetchrow_hashref()) {
    my $name = $row->{MapName};
    my $state = $row->{State};
    my $id = $row->{SBID};

    msg("Processing map: $name, $state <$id>", not $silent);

    db_transaction(sub {
      update_local_file($row);
      update_metadata($row);
    });
  }
}

################################################################################
sub update_local_file {
  my ($item) = @_;

  my $id = $item->{SBID};
  my $local_file = is_current($item);

  if ($local_file) {
    debug("Map is current: $local_file", $debug);

  } else {
    debug("Download required <$id>", $debug);
    $local_file = download_item($item);

    unless ($local_file) {
      error("Download failed for <$id>", not $silent);
    }
  }

  db_update_item($item->{SBID}, {
    LocalFilePath => $local_file,
    FileSize => ($local_file) ? -s $local_file : undef,
  });
}

################################################################################
sub update_metadata {
  my ($item) = @_;

  # TODO update from local file or geo_xml?
}

################################################################################
## MAIN ENTRY

db_migrate();

sb_update_catalog();

db_update_all();

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

Browse the collection here: L<https://www.sciencebase.gov/catalog/item/4f554236e4b018de15819c85>

=head1 REQUIREMENTS

=over

=item B<Log::Message::Simple> - debug and logging output

=item B<Parse::CSV> - used to parse the catalog file

=item B<Mozilla::CA> - recommended for HTTPS connections

=back

=head1 TODO

=over

=item Remove files from the data directory that are not in the catalog.

=item Improve check for a current file using PDF metadata.

=item Specify maximum number of maps to download per session (default to unlimited).

=item Use a lock file.

=item Mode to report catalog stats only (no download).

=back

=cut
