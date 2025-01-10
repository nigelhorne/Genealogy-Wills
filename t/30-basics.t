use strict;
use warnings;

use Test::Most tests => 6;   # Define the number of tests
use Genealogy::Wills;
use File::Temp qw(tempdir);

# Mock database
BEGIN {
	package Genealogy::Wills::wills;
	use strict;
	use warnings;
	sub new {
		my ($class, %args) = @_;
		return bless \%args, $class;
	}
	sub selectall_hashref {
		# Return mock data
		return [
			{ first => 'John', last => 'Smith', url => 'example.com/john_smith' },
			{ first => 'Jane', last => 'Smith', url => 'example.com/jane_smith' },
		];
	}
	sub fetchrow_hashref {
		# Return a single record
		return { first => 'John', last => 'Smith', url => 'example.com/john_smith' };
	}
}

# Test directory setup
my $temp_dir = tempdir(CLEANUP => 1);

# Test object creation
my $obj = Genealogy::Wills->new(directory => $temp_dir);
ok($obj, 'Object created successfully');

# Test object properties
is($obj->{directory}, $temp_dir, 'Directory property set correctly');

# Test search with valid parameters
my @results = $obj->search(last => 'Smith');
is(scalar(@results), 2, 'Search returned correct number of results');
is($results[0]->{first}, 'John', 'First result matches expected value');
like($results[0]->{url}, qr/^https:\/\//, 'URL in results is correctly formatted');

# Test search with missing parameters
dies_ok(sub { $obj->search() }, 'Search with missin parameters dies');
