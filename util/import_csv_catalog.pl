#!/usr/bin/perl -w

=pod

=head1 NAME

import_csv.pl -- Import a CSV catalog into the database, updating existing records as-needed.

=head1 SYNOPSIS

  import_csv.pl --catalog=file --database=file

=cut

################################################################################

use strict;

use DBI;
use Getopt::Long qw( :config bundling );
use Scalar::Util qw( looks_like_number );
use File::Spec;
use File::Find;
use File::Basename;
use Parse::CSV;
use Pod::Usage;

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

my $opt_datadir = undef;
my $opt_catalog = undef;
my $opt_help = 0;

GetOptions(
  'catalog|C=s' => \$opt_catalog,
  'datadir|D=s' => \$opt_datadir,
  'help|?' => \$opt_help
) or usage(1);

usage(0) if $opt_help;

usage('Catalog is required') unless defined $opt_catalog;
usage("File not found: $opt_catalog") unless -f $opt_catalog;

usage('Data directory is required') unless defined $opt_datadir;
usage("Directory not found: $opt_datadir") unless -d $opt_datadir;

my $catalog = File::Spec->rel2abs($opt_catalog);
my $datadir = File::Spec->rel2abs($opt_datadir);

################################################################################
# connect to database

my $db_file = File::Spec->join($datadir, 'index.db');

printf("Connecting to database: %s\n", $db_file);
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef);

sub migrate_db_schema {
  return unless m/\.sql$/;
  # TODO only execute if needed
  printf("Executing SQL update: %s\n", $_);
}

my $sqldir = File::Spec->join(dirname(__FILE__), '../sql');
$sqldir = File::Spec->rel2abs($sqldir);
find(\&migrate_db_schema, $sqldir);

################################################################################
# process the catalog

printf("Loading catalog: %s\n", $catalog);

my $csv = Parse::CSV->new(
  file => $catalog,
  names => 1,

  # only return current, US Topo maps
  filter => sub {
    (($_->{'Series'} eq 'US Topo') && ($_->{'Version'} eq 'Current')) ? $_ : undef
  }
);

my $item_count = 0;

while (my $item = $csv->fetch) {
  $item_count++;
}

printf("Imported %d items\n", $item_count);
