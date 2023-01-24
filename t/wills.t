#!perl -wT

use strict;
use Test::Most tests => 11;

use lib 'lib';
use lib 't/lib';
use MyLogger;

BEGIN {
	use_ok('Genealogy::Wills');
}

SKIP: {
	skip 'Database not installed', 10 if(!-r 'lib/Genealogy/Wills/database/obituaries.sql');

	if($ENV{'TEST_VERBOSE'}) {
		Genealogy::Wills::DB::init(logger => MyLogger->new());
	}
	my $search = new_ok('Genealogy::Wills');

	my @cowells = $search->search(last => 'Cowell');

	if($ENV{'TEST_VERBOSE'}) {
		diag(Data::Dumper->new([\@cowells])->Dump());
	}

	ok(scalar(@cowells) >= 1);
	# FIXME, test either last == Smith or maiden == Smith
	is($cowells[0]->{'last'}, 'Cowells', 'Returned Cowells');
}
