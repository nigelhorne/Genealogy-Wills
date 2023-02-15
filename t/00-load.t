#!perl -T

use strict;

use Test::Most tests => 2;

BEGIN {
	use_ok('Genealogy::Wills') || print 'Bail out!';
}

require_ok('Genealogy::Wills') || print 'Bail out!';
if(!-r 'lib/Genealogy/Wills/database/wills.sql') {
	diag('Database not installed');
	print 'Bail out!';
}

diag("Testing Genealogy::Wills $Genealogy::Wills::VERSION, Perl $], $^X");
