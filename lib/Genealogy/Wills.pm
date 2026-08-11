package Genealogy::Wills;

use strict;
use warnings;
use autodie qw(:all);
# Carp is intentionally NOT imported into this namespace. All calls must be
# fully-qualified (Carp::croak, Carp::carp) so that Test::Carp can intercept
# them at runtime. Bare imported aliases are compile-time copies and bypass
# the runtime override that Test::Carp installs.
use Carp ();
use Data::Reuse;
use Readonly;
use File::Spec;
use Genealogy::Wills::wills;
use Object::Configure 0.23;
use Params::Get 0.16;
use Params::Validate::Strict 0.37;
use Return::Set 0.05;
use Scalar::Util qw(blessed);

=encoding utf-8

=head1 NAME

Genealogy::Wills - Search a local database of historical wills

=head1 VERSION

Version 0.10

=cut

our $VERSION = '0.10';

# Named constants remove all magic literals from the code body.
# Readonly enforces immutability at runtime; any attempted mutation dies.
Readonly my $DEFAULT_CACHE_DURATION => '1 day';
Readonly my $MIN_LAST_NAME_LENGTH   => 1;
Readonly my $MAX_LAST_NAME_LENGTH   => 100;
# Computed once at module load so the year boundary stays current without
# redeployment. See LIMITATIONS for the year-boundary edge case.
Readonly my $MAX_WILL_YEAR => (localtime)[5] + 1900;

# P1: __FILE__ is resolved by the compiler; this never changes at runtime.
# Replaces Module::Info->new_from_loaded(__PACKAGE__)->file() which scans
# %INC and allocates a Module::Info object on every new() call that omits
# 'directory'. Computing it here gives zero per-call overhead.
my $MODULE_DATA_DIR = do {
	(my $dir = __FILE__) =~ s/\.pm\z//;
	File::Spec->catfile($dir, 'data');
};

# P2: The PVS schema is static. Allocating it once here avoids creating
# 6 anonymous hashrefs (the outer schema + 5 field specs) on every search()
# call. At 1000 searches/sec that eliminates 6000 transient allocations/sec.
my $SEARCH_SCHEMA = {
	'last' => {
		type    => 'string',
		min     => $MIN_LAST_NAME_LENGTH,
		max     => $MAX_LAST_NAME_LENGTH,
		# \z = strict end-of-string (not before \n); [-] at end = unambiguous literal
		# hyphen without escaping; /a = restrict \w to ASCII [0-9A-Za-z_], blocking
		# Unicode homograph queries (Cyrillic "Smith" silently returning zero results).
		matches => qr/^[\w-]+\z/a
	},
	'first' => {
		type     => 'string',
		optional => 1,
		min      => 1,
		max      => 100
	},
	'middle' => {
		type     => 'string',
		optional => 1,
		min      => 1,
		max      => 100
	},
	'town' => {
		type     => 'string',
		optional => 1,
		min      => 1,
		max      => 100
	},
	'year' => {
		type     => 'integer',
		optional => 1,
		min      => 1,
		max      => $MAX_WILL_YEAR
	},
};

=head1 DESCRIPTION

A "will" (short for "last will and testament") is a legal document in which a
person states who should receive their money and property after they die. Courts
record when a will is officially accepted (called "probate"). This module gives
you a simple way to search those records.

The data comes from the B<Kent Wills Transcript>, a free online collection of
wills proved in Kent, covering roughly the 1500s through the 1900s.
That data is stored in a local SQLite file (C<wills.sql>), so B<no internet
connection is needed> when you run a search. The database is built once by
running C<perl bin/create_db.PL>.

Each record in the database describes one will and contains:

=over 4

=item * The person's first name, optional middle name, and last name (surname).

=item * The town where the person lived or died.

=item * The year the will was proved (officially accepted by the court).

=item * A URL linking to the original entry on the Kent Wills Transcript website.

=back

Using the module is a two-step process: create one C<Genealogy::Wills> object
with C<new()>, then call C<search()> as many times as you like.

=head1 SYNOPSIS

    use Genealogy::Wills;

    # -------------------------------------------------------------------
    # Example 1: Find all records for a given last name.
    # -------------------------------------------------------------------
    my $wills = Genealogy::Wills->new();
    die "Could not load wills database" unless defined $wills;

    my @smiths = $wills->search(last => 'Smith');
    for my $r (@smiths) {
        printf "%s %s, %s (%d)\n  %s\n\n",
            $r->{first}, $r->{last},
            $r->{town},  $r->{year},
            $r->{url};
    }

    # -------------------------------------------------------------------
    # Example 2: Short form -- pass just the last name as a plain string.
    # -------------------------------------------------------------------
    my @joneses = $wills->search('Jones');

    # -------------------------------------------------------------------
    # Example 3: Narrow by first name, town, and year.
    # -------------------------------------------------------------------
    my @johns = $wills->search(
        first => 'John',
        last  => 'Smith',
        town  => 'Canterbury, Kent, England',
        year  => 1750,
    );

    # -------------------------------------------------------------------
    # Example 4: Scalar context -- get only the first matching record.
    # Use this when you want one result, not a list.
    # -------------------------------------------------------------------
    my $will = $wills->search(last => 'Carlton');
    if (defined $will) {
        print "First match: $will->{first} $will->{last} ($will->{year})\n";
        print "See: $will->{url}\n";
    } else {
        print "No record found.\n";
    }

    # -------------------------------------------------------------------
    # Example 5: Check whether anything was found.
    # -------------------------------------------------------------------
    my @results = $wills->search(last => 'Xyz');
    if (@results) {
        print scalar(@results), " records found.\n";
    } else {
        print "No records found.\n";
    }

    # -------------------------------------------------------------------
    # Example 6: Point at a different database directory.
    # -------------------------------------------------------------------
    my $wills2 = Genealogy::Wills->new(directory => '/var/data/wills');

    # -------------------------------------------------------------------
    # Example 7: Load settings from a config file.
    # The YAML key must use double underscores: Genealogy__Wills
    # -------------------------------------------------------------------
    # Contents of /etc/wills.yml:
    #   Genealogy__Wills:
    #     directory: /var/data/wills
    my $wills3 = Genealogy::Wills->new(config_file => '/etc/wills.yml');

    # -------------------------------------------------------------------
    # Example 8: Clone an existing object, changing one setting.
    # -------------------------------------------------------------------
    my $wills4 = $wills->new(cache_duration => '12 hours');

=head1 SUBROUTINES/METHODS

=head2 new

Creates and returns a C<Genealogy::Wills> object.

No arguments are required. All arguments are optional and may be passed in any
of these forms:

    Genealogy::Wills->new()                        # no arguments
    Genealogy::Wills->new(key => value, ...)       # flat key-value list
    Genealogy::Wills->new({ key => value, ... })   # hash reference
    Genealogy::Wills->new('/path/to/data')         # single string = directory

B<Returns> the new object on success, or C<undef> on failure (for example,
if the database directory does not exist). A warning is printed to explain
what went wrong.

B<Always check the return value> before calling C<search()>. If C<new()>
returns C<undef> and you ignore it, a call to C<search()> will crash your
program later with a confusing error.

    my $wills = Genealogy::Wills->new();
    die "Could not load database" unless defined $wills;

=head3 ARGUMENTS

=over 4

=item * C<directory> (optional, string)

The path to the directory that contains the C<wills.sql> file.

If you do not provide this, the module uses its own built-in data directory,
which is set up when you run C<perl bin/create_db.PL>.

You can also pass a single bare string as a shortcut:

    Genealogy::Wills->new('/path/to/data')
    # is the same as
    Genealogy::Wills->new(directory => '/path/to/data')

=item * C<config_file> (optional, string)

Path to a configuration file in C<YAML>, C<XML>, C<INI>, or another format
supported by L<Object::Configure>.

The file must have a top-level section named C<Genealogy__Wills> (the class
name with C<::> replaced by C<__>). For example:

    # /etc/wills.yml
    Genealogy__Wills:
      directory: /var/data/wills

Environment variables of the form C<Genealogy__Wills__key> override values
read from the file. For example, setting
C<Genealogy__Wills__directory=/tmp/wills> in the shell overrides the
C<directory> from the file.

B<Croaks> (the program stops with an error message) if you provide a
C<config_file> path that does not exist or cannot be read.

=item * C<logger> (optional, object)

An object used to write diagnostic messages. It must have both an C<info()>
method and an C<error()> method. Any L<Log::Log4perl> logger, or any object
that implements those two methods, works.

B<Croaks> if an object is provided but is missing the required methods.

=item * C<cache_duration> (optional, string)

How long the underlying C<Database::Abstraction> layer caches query results.
Default is C<'1 day'>. Accepts strings like C<'12 hours'>, C<'2 days'>.

=back

=head3 RETURNS

On success: a C<Genealogy::Wills> object.

On failure: C<undef>, with a warning printed to STDERR naming the problem.

=head3 EXAMPLE

    # Minimal -- uses the bundled database
    my $w = Genealogy::Wills->new();
    die "Failed to load database" unless defined $w;

    # Explicit directory path
    my $w = Genealogy::Wills->new(directory => '/data/kent-wills');

    # Hash-reference form (same result)
    my $w = Genealogy::Wills->new({ directory => '/data/kent-wills' });

    # Single-string shortcut (treated as the directory path)
    my $w = Genealogy::Wills->new('/data/kent-wills');

    # From a YAML config file
    my $w = Genealogy::Wills->new(config_file => '/etc/wills.yml');

    # Clone an existing object, changing the cache duration
    my $w2 = $w->new(cache_duration => '12 hours');

=head3 API SPECIFICATION

=head4 input

C<new()> uses C<Params::Get> to normalize its arguments but does not apply
C<Params::Validate::Strict> validation. The recognized parameters are:

    # Params::Get::get_params(undef, @_) -- normalizes to a hashref.
    # Accepted as: flat list, hash reference, or a single string (= directory).
    {
        directory      => { type => 'string' },   # readable directory path
        config_file    => { type => 'string' },   # readable path; croaks if missing
        logger         => { type => 'object',
			    can => [ 'info', 'error' ],
                            optional => 1
			  },
        cache_duration => { type => 'string',
			    default => '1 day',
                            optional => 1
			  },
    }

=head4 output

    # Return::Set is not used by new().
    output => {
    	type => 'hashref',
	optional => 1
    }

=head3 MESSAGES

=over 4

=item B<Can't load configuration from E<lt>pathE<gt>>

Fatal. The C<config_file> path was given but the file is missing or
unreadable. Check the path and file permissions.

=item B<Logger must be an object with info() and error() methods>

Fatal. The C<logger> argument is not an object, or is missing C<info()>
or C<error()>. Pass a compatible logger such as L<Log::Log4perl>.

=item B<Genealogy::Wills: E<lt>dirE<gt> is not a directory>

Warning (not fatal). The resolved directory does not exist or cannot be read.
C<new()> returns C<undef>. Verify the path; if using the bundled database run
C<perl bin/create_db.PL>.

=back

=cut

sub new {
	my $class = shift;
	my $params;

	if((scalar(@_) == 1) && !ref($_[0])) {
		$params->{'directory'} = $_[0];
	} else {
		$params = Params::Get::get_params(undef, \@_);
	}

	# Premise: $class is one of three mutually exclusive types:
	#   (a) undef   -- ::new() function form; any arg would have become $class
	#   (b) blessed -- called on an existing object (clone request)
	#   (c) string  -- called as Genealogy::Wills->new() class method
	if(!defined($class)) {
		# (a) ::new() with no args. Params::Get returns {} for empty input,
		#     so no inner check is needed -- the carp branch was unreachable.
		#     Conclusion: default the class to this package and proceed normally.
		$class = __PACKAGE__;
	} elsif(blessed($class)) {
		# (b) Clone the object. Merge caller overrides on top of the original;
		# // {} handles the no-args case where Params::Get returns undef.
		return bless { %{$class}, %{$params // {}} }, ref($class);
	}
	# Post-condition: $class is now a valid package name string.

	if(defined($params->{'config_file'}) && !-r $params->{'config_file'}) {
		Carp::croak("Can't load configuration from " . $params->{'config_file'});
	}
	$params = Object::Configure::configure($class, $params);

	# P1: use the compile-time constant; no %INC scan, no object allocation.
	$params->{'directory'} //= $MODULE_DATA_DIR;

	# P3: -d fills the OS stat cache; -r _ reads it without a second syscall.
	unless(-d $params->{'directory'} && -r _) {
		Carp::carp(__PACKAGE__ . ': ' . $params->{'directory'} . ' is not a directory');
		return;
	}

	if(defined $params->{'logger'}) {
		# Modus Tollens: if the logger cannot satisfy required capabilities, reject now.
		my $l = $params->{'logger'};
		Carp::croak('Logger must be an object with info() and error() methods')
			unless blessed($l) && $l->can('info') && $l->can('error');
	}

	# cache_duration defaults to the module constant; callers may override it.
	return bless {
		cache_duration => $DEFAULT_CACHE_DURATION,
		%{$params}
	}, $class;
}

=head2 search

Search the wills database for records that match the criteria you provide.

The last name (C<last>) is the only required field. All other fields are
optional and narrow the results further. If more than one field is given, a
record must match B<all> of them to be returned.

B<Important -- context matters>: what you get back depends on how you call the
method:

=over 4

=item * B<List context> (C<my @results = $w-E<gt>search(...)>)

Returns B<all> matching records as a list of hash references. Returns an empty
list (C<()>) when nothing matches.

=item * B<Scalar context> (C<my $result = $w-E<gt>search(...)>)

Returns B<one> hash reference (the first match found), or C<undef> when
nothing matches.

=back

Each returned hash reference has these keys:

    first  -- first name (string)
    last   -- last name (string)
    middle -- middle name (string, or undef if not recorded)
    town   -- town, e.g. "Canterbury, Kent, England" (string, or undef)
    year   -- year the will was proved (integer, or undef)
    url    -- full URL to the source page, e.g. "https://freepages..."

The C<url> field always starts with C<https://>.

=head3 ARGUMENTS

=over 4

=item * C<last> (required, string)

The surname (last name, family name) to search for.

Must be non-empty and contain only letters, digits, underscores (the C<\w>
set), and hyphens. Any other characters (including apostrophes) cause the
call to fail validation. For example, C<"O'Brien"> must be passed as
C<"OBrien">.

The search is B<exact-match>: C<"Smith"> finds only the exact string
C<"Smith">, not C<"Smithson">.

=item * C<first> (optional, string, 1-100 characters)

The first name (given name) to filter by.

=item * C<middle> (optional, string, 1-100 characters)

The middle name to filter by.

=item * C<town> (optional, string, 1-100 characters)

The town to filter by. Records use the format C<"Townname, Kent, England">.
Use the exact spelling seen in earlier results, or leave this out and
narrow by other fields instead.

=item * C<year> (optional, integer, 1 to current year)

The year the will was proved. Must be a positive whole number no greater
than the current calendar year.

=back

You may pass arguments in three ways:

    $w->search(last => 'Smith')              # flat key-value list
    $w->search({ last => 'Smith' })          # hash reference
    $w->search('Smith')                      # bare string = last name only

=head3 RETURNS

B<List context>: a list of hash references (may be empty).

B<Scalar context>: one hash reference, or C<undef> if nothing matched.

Each hash reference has these keys: C<first>, C<last>, C<middle>, C<town>,
C<year>, C<url>.

=head3 EXAMPLE

    my $w = Genealogy::Wills->new();

    # All records for the surname "Cowell"
    my @all = $w->search(last => 'Cowell');
    print scalar(@all), " records found.\n";

    # Bare string shortcut
    my @smiths = $w->search('Smith');

    # Multiple filters
    my @hits = $w->search(
        first => 'Stephen',
        last  => 'Carlton',
        town  => 'Ash, Kent, England',
    );

    # Scalar context: one result or undef
    my $one = $w->search(last => 'Horne');
    if (defined $one) {
        printf "%s %s (%d): %s\n",
            $one->{first}, $one->{last}, $one->{year}, $one->{url};
    }

    # url always starts with https://
    for my $r ($w->search(last => 'Smith')) {
        print $r->{url}, "\n";
    }

=head3 API SPECIFICATION

=head4 input

    schema => {
        last   => { type => 'string',
                    min  => 1, max => 100,
                    matches => qr/^[\w-]+\z/a },
        first  => { type => 'string',
                    min  => 1, max => 100,
                    optional => 1 },
        middle => { type => 'string',
                    min  => 1, max => 100,
                    optional => 1 },
        town   => { type => 'string',
                min  => 1, max => 100,
                    optional => 1 },
        year   => { type => 'integer',
                    min  => 1, max => $MAX_WILL_YEAR,
                    optional => 1 },
    };

C<$MAX_WILL_YEAR> is C<(localtime)[5] + 1900> computed once at module load.
C<Params::Get::get_params('last', ...)> maps a bare string argument to
C<< { last => $string } >> before validation runs.
The schema hashref itself is a module-level constant allocated once at load
time and shared across all calls; it is never modified at runtime.

=head4 output

    # List context -- no Return::Set wrapping
    Returns: Array of HashRef
             Each HashRef: { first  => { type => 'string',  optional => 1 },
                             last   => { type => 'string' },
                             middle => { type => 'string',  optional => 1 },
                             town   => { type => 'string',  optional => 1 },
                             year   => { type => 'integer', optional => 1 },
                             url    => { type => 'string',  matches  => qr/^https:\/\// },
                           }
             Empty list when nothing matches.

    # Scalar context -- wrapped by Return::Set
    Return::Set::set_return($will, { type => 'hashref', min => 1 });
    Returns: HashRef (same shape) | undef

=head3 MESSAGES

=over 4

=item B<search() must be called on an object>

Fatal. You called C<search()> as a class method
(C<Genealogy::Wills-E<gt>search(...)>) instead of on an object. Create the
object first with C<new()>, then call C<search()> on it.

=item B<Usage: search({ last =E<gt> $last_name })>

Fatal. C<search()> was called with no arguments at all.
Always provide at least C<last =E<gt> $name>.

=item B<Value for 'last' is mandatory>

Warning (not fatal). The C<last> argument was provided but its value was
C<undef> or an empty string. C<search()> returns no results in this case.
Supply a non-empty string.

=item B<Can't open the wills database>

Fatal. The internal database object could not be created. The database file
may be missing or corrupted. Rebuild with C<perl bin/create_db.PL -f>.

=back

=head3 PSEUDOCODE

A plain-English description of what C<search()> does, step by step:

    1. If the caller is not a Genealogy::Wills object, die immediately.

    2. If no arguments were given, die immediately.

    3. Parse the arguments:
         - A single bare string becomes { last => $string }.
         - A hash reference or flat key-value list is used as-is.

    4. Validate the parsed arguments:
         - 'last' must match /^[\w-]+$/ and be 1-100 characters.
         - 'first', 'middle', 'town': optional strings, 1-100 characters each.
         - 'year': optional integer between 1 and the current year.

    5. If 'last' is undef or empty after parsing, print a warning and return
       nothing (an empty list or undef, depending on context).

    6. (Removed: sanitization was a no-op. Validation in step 4 already
       enforces [\w-] only via PVS matches => qr/^[\w-]+\z/a.)

    7. If this is the first search() call on this object, open the SQLite
       database. Reuse the existing connection on subsequent calls.

    8. If the database could not be opened, die immediately.

    9. Execute the query:
         List context:
           Fetch all matching rows.
           Prepend "https://" to the url of every row.
           Intern all strings (Data::Reuse::fixate) to save memory.
           Return the list of hashrefs.

         Scalar context:
           Fetch the first matching row.
           Prepend "https://" to its url.
           Intern all strings.
           Return the hashref (or undef if nothing matched).

=cut

sub search {
	my $self = shift;

	Carp::croak('search() must be called on an object') unless blessed($self);
	Carp::croak('Usage: search({ last => $last_name })') unless @_;

	# P2: $SEARCH_SCHEMA is the module-level constant; no per-call allocation.
	my $params = Params::Validate::Strict::validate_strict({
		args   => Params::Get::get_params('last', @_),
		schema => $SEARCH_SCHEMA,
	});

	unless(length($params->{'last'} // '')) {
		Carp::carp("Value for 'last' is mandatory");
		return;
	}
	# P4 (Transitive Reduction): PVS already enforced matches => qr/^[\w-]+\z/a above.
	# Any value reaching this point is structurally valid; re-sanitization is a no-op.

	$self->{'wills'} ||= Genealogy::Wills::wills->new(no_entry => 1, no_fixate => 1, %{$self});

	Carp::croak("Can't open the wills database") unless defined($self->{'wills'});

	if(wantarray) {
		# P5: normalize to [] so the loop and return are unconditional;
		# eliminates a branch and makes the empty-result path explicit.
		my $wills = $self->{'wills'}->selectall_hashref($params) // [];
		$_->{'url'} = 'https://' . $_->{'url'} for @{$wills};
		Data::Reuse::fixate(@{$wills});
		return @{$wills};
	}
	if(defined(my $will = $self->{'wills'}->fetchrow_hashref($params))) {
		$will->{'url'} = 'https://' . $will->{'url'};
		Data::Reuse::fixate(%{$will});
		return Return::Set::set_return($will, { 'type' => 'hashref', 'min' => 1 });
	}
	return;
}

=head1 COMMON PITFALLS

This section describes the most common mistakes when using this module.
Read it before reporting a bug.

=head2 List context vs. scalar context give different results

This is the single most important thing to understand. The same call returns
different things depending on whether you store the result in an array or a
scalar variable:

    my @all   = $wills->search(last => 'Smith');  # ALL Smiths (may be many)
    my $first = $wills->search(last => 'Smith');  # ONE Smith only

If you accidentally write C<my $r = $wills-E<gt>search(...)>, you get at most
one record even if hundreds matched. Use C<my @results = ...> unless you
specifically want only the first match.

=head2 new() returns undef on failure -- it does not crash

If the directory does not exist or cannot be read, C<new()> prints a warning
and returns C<undef>. Your program does B<not> stop. If you then call
C<search()> on the C<undef> value, it will crash later with an unhelpful error.

Always check the return value:

    my $wills = Genealogy::Wills->new();
    die "Could not load wills database" unless defined $wills;

=head2 No arguments is fatal; undef is only a warning

These two situations look similar but have very different consequences:

    $wills->search();               # FATAL -- program stops with an exception
    $wills->search(last => undef);  # WARNING only -- returns no results

Always provide at least C<last =E<gt> $name>.

=head2 The url field already contains https://

Every returned record has its C<url> field set to a full URL starting with
C<https://>. Do not add the scheme prefix yourself:

    print $r->{url};               # correct: https://freepages.rootsweb.com/...
    print 'https://' . $r->{url}; # WRONG:   https://https://freepages...

=head2 Apostrophes and punctuation are rejected in last names

The module accepts only word characters (C<\w>) and hyphens in the C<last>
argument. Any other character -- including apostrophes -- causes validation
to fail, not silent stripping.

    $wills->search(last => "O'Brien");  # FAILS validation; pass "OBrien"

If the record you are looking for has a name like C<O'Brien>, search for
C<OBrien> instead (that is how it was recorded in the database).

=head2 Search is exact-match -- no wildcards or fuzzy matching

The query looks for an exact match on every field you provide. Partial
last names and wildcard patterns (such as C<Smith*>) are not supported
through this interface.

    $wills->search(last => 'Smith');  # finds "Smith" only
    # Does NOT find "Smithson", "Blacksmith", "Goldsmith", etc.

=head2 The config file key uses double underscores, not colons

When using a YAML (or other) config file, the section name for this class
must use two underscores in place of each C<::> in the package name:

    # CORRECT
    Genealogy__Wills:
      directory: /var/data/wills

    # WRONG (causes the config to be silently ignored)
    Genealogy::Wills:
      directory: /var/data/wills

The same rule applies to environment variable overrides:
C<Genealogy__Wills__directory=/tmp/wills>.

=head2 Do not use the function-call syntax with arguments

Calling C<new()> as a plain function (C<::> instead of C<-E<gt>>) with
arguments does not work correctly. The first argument is misread as the
class name.

    Genealogy::Wills->new()            # correct -- arrow syntax
    Genealogy::Wills::new()            # tolerated -- no args, defaults to package
    Genealogy::Wills::new('/data')     # WRONG -- '/data' is misused as class name

=head2 The year upper limit is fixed when the module loads

The maximum allowed C<year> value is computed once the first time
C<use Genealogy::Wills> is executed. If your process runs for a very long
time and crosses a year boundary (e.g. from 31 December to 1 January), the
cap will be stale by one year until the module is reloaded.

=head1 LIMITATIONS

=over 4

=item * Only data from Kent is available at the moment.

=item * B<C<::new()> with arguments is unsupported.>

C<Genealogy::Wills::new('Smith')> shifts C<'Smith'> into C<$class> and
attempts to bless into it. Only the no-argument form
C<Genealogy::Wills::new()> is partially handled (it defaults to
C<__PACKAGE__>). Always use the arrow form: C<< Genealogy::Wills->new() >>.

=item * B<Private methods are unenforced.>

There are currently no private helper methods. If internal helpers are added
they should be marked with C<Sub::Private> (C<:Private> attribute) to prevent
accidental external use, and C<Sub::Protected> for subclass-only methods.

=item * B<Year upper bound is capped at load time.>

C<MAX_WILL_YEAR> is computed once when the module is first loaded. In the
unlikely event the module remains loaded across a year boundary the cap will
be one year stale.

=item * B<No full-text or fuzzy search.>

Searches are exact-match on the columns provided. There is no fuzzy or
phonetic matching (e.g. Soundex, Levenshtein distance). Wildcard support
depends on the C<Database::Abstraction> layer.

=item * B<The C<logger> argument is silently discarded.>

C<Object::Configure> always supplies its own C<Log::Abstraction> logger.
Any object passed as C<logger> to C<new()> is replaced before it is stored.
See the L</SECURITY> section, Finding 3.

=item * B<Single database source.>

The data comes from a single scraped source (the Kent Wills Transcript). It
does not cover wills from other counties or archives.

=back

=head1 SECURITY

This section documents the attack surface of the module, the controls in
place, and known open findings. It is intended for developers integrating
this module into a web application or CGI script.

=head2 Attack surface summary

The module has two entry points: C<new()> and C<search()>. Neither reads
from C<%ENV>, C<STDIN>, or any HTTP source directly. In a CGI context,
the calling script is responsible for parsing HTTP inputs before passing
them to this module.

=head2 Controls in place

=over 4

=item * C<last> is strictly validated

C<Params::Validate::Strict> enforces C<matches =E<gt> qr/^[\w-]+\z/a> on
the C<last> argument before any database call. This blocks SQL injection,
XSS, shell metacharacters, CRLF sequences, and null bytes for that field.
The C</a> modifier restricts C<\w> to ASCII C<[0-9A-Za-z_]>, blocking
Unicode homograph queries. The C<\z> anchor is strictly end-of-string,
unlike C<$> which matches before a trailing newline.

=item * C<year> is range-validated as an integer

C<Params::Validate::Strict> enforces C<type =E<gt> 'integer'>, C<min =E<gt> 1>,
and C<max =E<gt> MAX_WILL_YEAR>. Non-integer strings, floats, and
out-of-range values are all rejected before DB access.

=item * Directory and config-file paths are checked before use

C<new()> verifies C<-d $dir && -r _> for the data directory and C<-r>
for any C<config_file>. Paths that do not pass these checks cause C<new()>
to return C<undef> (with a warning) or croak immediately.

=item * Logger injection is blocked by Object::Configure

C<Object::Configure::configure()> always replaces the caller-supplied
C<logger> argument with its own C<Log::Abstraction> object, regardless
of what was passed. A hostile logger (missing methods, wrong type, or
carrying malicious extra methods) is discarded before any logging call
occurs. The module-level interface check C<(blessed && can 'info' && can 'error')>
runs against the C<Object::Configure>-supplied logger, which always passes.

=item * No shell operations

The module performs no C<system()>, C<exec()>, backtick, or
C<open(FH, "...|")> calls. Shell metacharacters in any field pose no
command-injection risk within this module.

=item * Database access is parameterised

All SQL is executed via C<Database::Abstraction> (v0.37+), which uses
DBI prepared statements. Values are bound as parameters, not interpolated
into SQL strings.

=back

=head2 Known findings

=over 4

=item * B<Finding 1: C<first>, C<middle>, C<town> have no character-set constraint>

These optional fields are validated for type (string) and length (1-100)
only. SQL injection characters such as C<'>, C<;>, C<-->, and C<UNION>
pass C<Params::Validate::Strict> for these fields and are forwarded to
the database layer verbatim.

B<Current mitigation>: C<Database::Abstraction> uses DBI parameterised
queries, so the values are bound safely regardless of their content.

B<Recommended defence-in-depth>: add C<matches> constraints to the schema
for these fields, for example C<qr/^[\w\s\-,.]+$/>.

B<Test coverage>: C<t/cgi_security.t>, section 10.

=item * B<Finding 2 (fixed): C<matches =E<gt> qr/^[\w-]+\z/a> — Unicode and trailing-newline issues resolved>

The C<\w> class without C</a> matched Unicode word characters (Cyrillic,
Greek, Hebrew, etc.), allowing a homograph query such as C<"\x{0430}mith">
to pass validation silently (returning zero results, not an error).

Additionally, the former C<$> anchor matches before a trailing C<\n>,
meaning C<"Smith\n"> would have passed the pattern.

B<Applied fix>: the schema now uses C<qr/^[\w-]+\z/a>: C</a> restricts
C<\w> to ASCII C<[0-9A-Za-z_]>, and C<\z> anchors to the absolute
end-of-string with no C<\n> exception. The C<\-> escape inside C<[]>
has also been normalised to the idiomatic unescaped C<-> at the end
of the character class.

B<Test coverage>: C<t/cgi_security.t>, section 19.

=item * B<Finding 3: caller-supplied logger is silently discarded>

C<Object::Configure> always replaces the C<logger> argument with a
C<Log::Abstraction> instance. A caller who passes a custom logger (for
example, a C<Log::Log4perl> object) will find it silently ignored. The
POD documents this parameter, but its effect is a no-op.

B<Impact>: this is a usability limitation, not a security risk.

B<Test coverage>: C<t/cgi_security.t>, section 15.

=back

=head1 FORMAL SPECIFICATION

System-level Z-notation for C<Genealogy::Wills>. The C<search()>
function's specification also appears in detail under its own section above.

    -- Scalar type definitions
    NAME     == seq₁ CHAR      -- non-empty character sequence
    PATHNAME == seq₁ CHAR      -- non-empty filesystem path
    YEAR     == 1 .. MaxYear   -- positive integer up to the current year

    -- The database object created by new()
    WillsDatabase
      directory      : PATHNAME
      cache_duration : seq CHAR
      records        : ℙ WillRecord

    -- Successful construction invariant
    ┌ InitWillsDatabase ─────────────────────────────────┐
    │ WillsDatabase                                       │
    │ ──────────────────────────────────────────────────  │
    │ ∃ d : PATHNAME • directory = d ∧ is_readable(d)    │
    │ cache_duration = "1 day"                            │
    │ records = load_sqlite(directory ++ "/wills.sql")    │
    └─────────────────────────────────────────────────────┘

    -- search() function: see FORMAL SPECIFICATION under search() above

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 BUGS

Please report bugs at
L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Genealogy-Wills>
or by email to C<bug-Genealogy-Wills@rt.cpan.org>.

When reporting a bug, please include:

=over 4

=item * The version of this module (run C<perl -MGenealogy::Wills -e 'print $Genealogy::Wills::VERSION'>).

=item * The version of Perl (run C<perl -V>).

=item * A short script that shows the problem.

=back

=head1 SEE ALSO

=over 4

=item * The Kent Wills Transcript

L<https://freepages.rootsweb.com/~mrawson/genealogy/wills.html>

=item * L<Database::Abstraction> -- the SQL layer used internally by this module.

=item * L<Configure an Object at Runtime|Object::Configure>

=item * L<Test Dashboard|https://nigelhorne.github.io/Genealogy-Wills/coverage/>

=item * L<Return::Set> -- enforces return-type contracts on C<search()>.

=back

=head1 SUPPORT

This module is provided as-is without any warranty.

You can find documentation for this module with the perldoc command:

    perldoc Genealogy::Wills

Other resources:

=over 4

=item * MetaCPAN

L<https://metacpan.org/release/Genealogy-Wills>

=item * RT: CPAN's request tracker

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Genealogy-Wills>

=item * CPAN Testers' Matrix

L<http://matrix.cpantesters.org/?dist=Genealogy-Wills>

=item * CPAN Testers Dependencies

L<http://deps.cpantesters.org/?module=Genealogy::Wills>

=back

=head1 FORMAL SPECIFICATION

=head2 search

The following Z-notation gives the precise mathematical meaning of C<search()>.
Optional fields that the caller did not supply are modelled as undefined.

    -- Type aliases
    NAME == seq₁ CHAR       -- a non-empty sequence of characters
    YEAR == 1 .. MaxYear    -- positive integer bounded by current year

    -- One record stored in the database
    WillRecord
      first  : NAME
      last   : NAME
      middle : NAME | undefined
      town   : NAME | undefined
      year   : YEAR | undefined
      url    : NAME           -- stored without "https://"; prefixed by search()

    -- Parameters passed to search()
    SearchParams
      last   : NAME
      first  : NAME | undefined
      middle : NAME | undefined
      town   : NAME | undefined
      year   : YEAR | undefined

    -- Invariant: last name must be non-empty
    ┌ SearchParams ──────────────────┐
    │ last : NAME                    │
    │ ─────────────────────────────  │
    │ last ≠ ⟨⟩                      │
    └────────────────────────────────┘

    -- Predicate: does record r satisfy all supplied parameters?
    matches : WillRecord × SearchParams → BOOL
    matches(r, p) ==
        r.last = p.last
        ∧  (p.first  = undefined  ∨  r.first  = p.first)
        ∧  (p.middle = undefined  ∨  r.middle = p.middle)
        ∧  (p.town   = undefined  ∨  r.town   = p.town)
        ∧  (p.year   = undefined  ∨  r.year   = p.year)

    -- Function signature
    search : WillsDatabase × SearchParams → ℙ WillRecord

    -- When last is non-empty, return all records that match
    ∀ db : WillsDatabase; p : SearchParams •
        p.last ≠ ⟨⟩  ⟹
            search(db, p) = { r : WillRecord | r ∈ db.records ∧ matches(r, p) }

    -- When last is empty, return nothing
    ∀ db : WillsDatabase; p : SearchParams •
        p.last = ⟨⟩  ⟹
            search(db, p) = ∅

=head1 LICENSE AND COPYRIGHT

Copyright 2023-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it, please let me know.

=cut

1;
