#!/usr/bin/env perl

# Create SQLite3 from https://freepages.rootsweb.com/~mrawson/genealogy/wills.html
#
# -f:	force a build, otherwise it won't build on CPAN smokers or if the
#	database is less than a day old

use strict;
use warnings;
use autodie qw(:all);
use feature 'state';
use DBI;
use File::HomeDir;
use File::Spec;
use HTML::Entities;
use HTTP::Cache::Transparent;
use LWP::ConnCache;
use LWP::UserAgent::WithCache;
use Lingua::EN::NameCase qw(nc);
use Try::Tiny;

BEGIN {
	$SIG{__WARN__} = sub {
		my $warning = shift;
		if(($warning =~ /^Use of uninitialized value/) ||
		   ($warning =~ /isn't numeric in numeric eq /i)) {
			die $warning;
		}
		warn $warning;
	}
}

my $force_flag;
my $dir  = 'lib/Genealogy/Wills/data';
my $bdir = File::Spec->catdir('blib', $dir);

if(defined($ARGV[0]) && ($ARGV[0] eq '-f')) {
	$force_flag++;
} elsif($ENV{'AUTOMATED_TESTING'}) {
	if(!-d $dir) {
		mkdir $dir, 0755;
	}
	exit;
}

if(!-d $dir) {
	mkdir $dir, 0755;
}

my $filename = File::Spec->catdir($dir, 'wills.sql');

if(!-d $dir) {
	mkdir $dir, 0755;
}

if(-r $filename) {
	# Don't bother downloading if the file is less than a day old
	if(((-s $filename) > 0) && (-M $filename < 1) && !$force_flag) {
		_sync_to_blib();
		exit;
	}
	unlink $filename;
}

my $cache_dir = $ENV{'CACHE_DIR'} || $ENV{'CACHEDIR'};
if($cache_dir) {
	mkdir $cache_dir, 0700 if(!-d $cache_dir);
	$cache_dir = File::Spec->catfile($cache_dir, 'http-cache-transparent');
} else {
	$cache_dir = File::Spec->catfile(File::HomeDir->my_home(), '.cache', 'http-cache-transparent');
}

HTTP::Cache::Transparent::init({
	BasePath => $cache_dir,
	Verbose  => 0,
	NoUpdate => 60 * 60 * 24 * 7 * 31,	# The archive never changes
	MaxAge   => 30 * 24
}) || die "$0: $cache_dir: $!";

my $ua = LWP::UserAgent::WithCache->new(timeout => 10, keep_alive => 1);
$ua->env_proxy(1);
$ua->agent('Genealogy::Wills');
$ua->conn_cache()->total_capacity(undef);
$Lingua::EN::NameCase::POSTNOMINAL = 0;

my $dbh = DBI->connect("dbi:SQLite:dbname=$filename", undef, undef, { RaiseError => 1, AutoCommit => 0, synchronous => 0, locking_mode => 'EXCLUSIVE' });
die "$filename: $!" if(!defined($dbh));

$dbh->do('PRAGMA cache_size = -65536');	# 64MB
$dbh->do('PRAGMA journal_mode = OFF');
$dbh->do('CREATE TABLE wills(first VARCHAR NOT NULL, middle VARCHAR, last VARCHAR NOT NULL, town VARCHAR, year INTEGER, url VARCHAR)');

my @queue;
foreach my $page ('ab', 'c', 'dg', 'hj', 'km', 'nr', 'sv', 'wy') {
	mrawson($ua, $page);
	flush($dbh) if(scalar(@queue) > 200_000);
};

print ' ' x 78, "\r";

flush($dbh);

$dbh->commit();
$dbh->prepare('CREATE INDEX name_index ON wills(first, last)')->execute();
$dbh->prepare('CREATE INDEX name_index_year ON wills(first, last, year)')->execute();
$dbh->do('pragma optimize');
$dbh->disconnect();

print "\n";

_sync_to_blib();

sub _sync_to_blib {
	mkdir $bdir, 0755 unless -d $bdir;
	return unless -d $bdir && -r $filename;
	my $bfilename = File::Spec->catdir($bdir, 'wills.sql');
	unlink $bfilename if -e $bfilename;
	link $filename, $bfilename;
}

sub mrawson {
	my ($ua, $page) = @_;

	my $url = "https://freepages.rootsweb.com/~mrawson/genealogy/will_$page.html";

	$| = 1;
	printf "%-70s\r", $url;
	$| = 0;

	my $response = $ua->get($url);

	my $data;
	if($response->is_success) {
		$data = $response->decoded_content();
	} else {
		die "\n$url: ", $response->status_line();
	}

	$data =~ s/\r//g;
	my @lines = split(/$/ms, $data);

	while(my $line = shift(@lines)) {
		# LAST NAME, First Name; Place of Death; Newspaper date
		return if($line =~ /Created by/);

		next unless($line =~ /^\s*<li><a href="(.+)">(.+),\s+(.+)\s+<\/a> of (.+) (\d{4})/);
		my ($page, $last, $first, $town, $year) = ($1, normalise_name($2), normalise_name($3), $4, $5);

		queue("freepages.rootsweb.com/~mrawson/genealogy/$page", $first, $last, "$town, Kent, England", $year);
	}
}

sub queue {
	my ($url, $first, $last, $town, $year) = @_;

	my $columns = {
		url   => $url,
		first => $first,
		town  => $town,
		year  => $year
	};

	# TODO: combine these into one regex
	if($last =~ /(.+)\sAlias\s(.+)/) {
		push @queue, { %{$columns}, last => $1 };
		$last = $2;
	} elsif($last =~ /(.+)\/(.+)/) {
		push @queue, { %{$columns}, last => $1 };
		$last = $2;
	}

	$columns->{'last'} = $last;

	# Handle "Ash next Sandwich" by adding both Ash and Sandwich as well
	if($town =~ /^(.*) next (.*?),\s+(.*)/i) {
		push @queue, $columns;
		push @queue, { %{$columns}, town => "$1, $3" };
		push @queue, { %{$columns}, town => "$1, $2, $3" };

		$columns = { %{$columns} };	# Clone as we push refs
		$columns->{'town'} = "$2, $3";
	}

	push @queue, $columns;
}

sub flush {
	my $dbh = shift;

	# Remove duplicates, preserving first occurrence
	my (%seen, @deduped);
	for my $item (@queue) {
		my $k = join('|', map { $item->{$_} // '' } qw(first middle last town year url));
		push @deduped, $item unless $seen{$k}++;
	}

	my $sth = $dbh->prepare(
		'INSERT INTO wills(first, middle, last, town, year, url) VALUES (?, ?, ?, ?, ?, ?)'
	);

	for my $row (@deduped) {
		my ($first, $middle);
		if($row->{'first'} =~ /^(.+?)\s(.+)$/) {
			($first, $middle) = ($1, $2);
		} else {
			$first = $row->{'first'};
		}
		try {
			$sth->execute($first, $middle, $row->{'last'}, $row->{'town'}, $row->{'year'}, $row->{'url'});
		} catch {
			die "\nError in insert: $_";
		};
	}

	@queue = ();	# Make sure Perl really frees all memory
}

# Reduce the very large number of calls to Lingua::EN::NameCase
sub normalise_name {
	my $name = shift;
	state %cache;
	my $key = lc($name);
	return $cache{$key} if exists $cache{$key};
	return ($cache{$key} = nc($name));
}
