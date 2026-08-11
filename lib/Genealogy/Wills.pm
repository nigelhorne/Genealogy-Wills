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
use File::Spec;
use Genealogy::Wills::wills;
use Module::Info;
use Object::Configure 0.23;
use Params::Get 0.16;
use Params::Validate::Strict 0.37;
use Return::Set 0.05;
use Scalar::Util qw(blessed);

=head1 NAME

Genealogy::Wills - Lookup in a database of wills

=head1 VERSION

Version 0.10

=cut

our $VERSION = '0.10';

use constant {
	DEFAULT_CACHE_DURATION => '1 day',	# The database is updated daily
	MIN_LAST_NAME_LENGTH   => 1,
	MAX_LAST_NAME_LENGTH   => 100,
	# Computed once at load time so the schema stays current across years
	MAX_WILL_YEAR          => do { (localtime)[5] + 1900 },
};

=head1 DESCRIPTION

This module provides a convenient interface to search through a database of historical wills,
primarily focused on the Kent Wills Transcript.
It handles database connections, caching, and result formatting.

- Results are cached for 1 day by default
- Database connections are lazy-loaded
- Large result sets may consume significant memory

=head1 SYNOPSIS

    # See https://freepages.rootsweb.com/~mrawson/genealogy/wills.html
    use Genealogy::Wills;
    my $wills = Genealogy::Wills->new();
    # ...

=head1 SUBROUTINES/METHODS

=head2 new

Creates a C<Genealogy::Wills> object.

Takes up to three optional arguments as a hash, hashref, or key-value pairs.
Returns the new object, or C<undef> if the directory is invalid.

=over 4

=item * C<config_file>

Path to a configuration file (C<YAML>, C<XML>, C<INI>, etc.) whose top-level
key matching the class name supplies default parameters. Environment variables
of the form C<ClassName__key> override file values.
Croaks if the path is specified but the file does not exist or is not readable.

=item * C<directory>

Directory containing C<wills.sql>.
If not given, uses the module's own data directory (C<lib/Genealogy/Wills/data/>).

=item * C<logger>

An object with C<info()> and C<error()> methods; used by the underlying
C<Database::Abstraction> layer for diagnostics.

=back

=head3 EXAMPLE

    # Minimal - uses the bundled database
    my $wills = Genealogy::Wills->new();

    # Explicit directory
    my $wills = Genealogy::Wills->new(directory => '/data/wills');

    # From a YAML config file
    my $wills = Genealogy::Wills->new(config_file => '/etc/wills.yml');

=head3 API SPECIFICATION

    # Input (all optional)
    {
        config_file => Str,     # readable file path
        directory   => Str,     # readable directory path
        logger      => Object,  # must implement info() and error()
    }

    # Returns
    Genealogy::Wills object, or undef if directory is invalid.

=head3 MESSAGES

    Can't load configuration from <path>
        config_file was specified but the path is missing or unreadable.
        Resolution: verify path and permissions.

    Logger must be an object with info() and error() methods
        logger does not satisfy the required interface.
        Resolution: pass a compatible logger (e.g. Log::Log4perl).

    Genealogy::Wills: <dir> is not a directory
        The resolved directory does not exist or is not readable.
        Resolution: verify the path; rebuild the DB with bin/create_db.PL.

=cut

sub new {
	my $class = shift;
	my $params;

	if((scalar(@_) == 1) && !ref($_[0])) {
		$params->{'directory'} = $_[0];
	} else {
		$params = Params::Get::get_params(undef, \@_);
	}

	if(!defined($class)) {
		if((scalar keys %{$params}) > 0) {
			# Using Genealogy::Wills::new(), not Genealogy::Wills->new()
			Carp::carp(__PACKAGE__ . ': use ->new() not ::new() to instantiate');
			return;
		}

		# FIXME: this only works when no arguments are given
		$class = __PACKAGE__;
	} elsif(blessed($class)) {
		# clone the given object
		if($params) {
			return bless { %{$class}, %{$params} }, ref($class);
		}
		return bless $class, ref($class);
	}

	if(defined($params->{'config_file'}) && !-r $params->{'config_file'}) {
		Carp::croak("Can't load configuration from " . $params->{'config_file'});
	}
	$params = Object::Configure::configure($class, $params);

	unless($params->{'directory'}) {
		my $module_file = Module::Info->new_from_loaded(__PACKAGE__)->file();
		(my $module_dir = $module_file) =~ s/\.pm$//;
		$params->{'directory'} = File::Spec->catfile($module_dir, 'data');
	}

	unless((-d $params->{'directory'}) && (-r $params->{'directory'})) {
		Carp::carp(__PACKAGE__ . ': ' . $params->{'directory'} . ' is not a directory');
		return;
	}

	if(defined $params->{'logger'}) {
		unless(blessed($params->{'logger'}) && $params->{'logger'}->can('info') && $params->{'logger'}->can('error')) {
			Carp::croak('Logger must be an object with info() and error() methods');
		}
	}

	# cache_duration can be overridden by the args
	return bless {
		cache_duration => DEFAULT_CACHE_DURATION,
		%{$params}
	}, $class;
}

=head2 search

Search the wills database.

C<last> (last name) is mandatory and must be a non-empty string of word
characters (C<\w>) and hyphens only.
Croaks immediately if called with no arguments at all.

In list context returns an array of hashrefs (empty list when nothing matches).
In scalar context returns a single hashref wrapped in C<Return::Set> (undef
when nothing matches).
Every returned hashref has C<first>, C<last>, C<town>, C<year>, and C<url>
fields; C<url> has C<https://> prepended.

=head3 EXAMPLE

    my $wills = Genealogy::Wills->new();

    # All Smiths
    my @smiths = $wills->search(last => 'Smith');

    # Short form: single string is treated as the last name
    my @smiths = $wills->search('Smith');

    # Multi-field search
    my @joneses = $wills->search({ first => 'Mary', last => 'Jones', year => 1750 });

    print $smiths[0]->{'first'}, ' ', $smiths[0]->{'url'}, "\n";

=head3 API SPECIFICATION

    # Input
    {
        last   => Str,      # required; /^[\w-]+$/
        first  => Str,      # optional; 1-100 chars
        middle => Str,      # optional; 1-100 chars
        town   => Str,      # optional; 1-100 chars
        year   => Int,      # optional; 1 .. current year
    }

    # List context
    Returns: Array of HashRefs  (empty if no match)

    # Scalar context
    Returns: HashRef | undef

=head3 MESSAGES

    search() must be called on an object
        Called as Genealogy::Wills->search() (class method) instead of
        $obj->search().

    Usage: search({ last => $last_name })
        Called with no arguments.
        Resolution: provide at least last => $name.

    Value for 'last' is mandatory
        last was passed as undef or empty string.
        Resolution: supply a non-empty last name.

    Can't open the wills database
        The wills database object could not be initialised.
        Resolution: rebuild with bin/create_db.PL.

=head3 PSEUDOCODE

    search(self, args):
        croak unless self is a blessed object
        croak with Usage if no args provided
        params = parse_and_validate(args)     # Params::Get + Params::Validate::Strict
        carp and return if params.last is empty/undef
        sanitize params.last (strip non-[\w-])
        initialise DB connection if not already open
        croak if DB connection failed
        if list context:
            rows = selectall_hashref(params)
            prepend https:// to each url
            fixate strings for memory efficiency
            return @rows
        else:
            row = fetchrow_hashref(params)
            prepend https:// to url
            fixate strings
            return row via Return::Set

=cut

sub search {
	my $self = shift;

	Carp::croak('search() must be called on an object') unless blessed($self);
	Carp::croak('Usage: search({ last => $last_name })') unless @_;

	my $params = Params::Validate::Strict::validate_strict({
		args   => Params::Get::get_params('last', @_),
		schema => {
			'last' => {
				type    => 'string',
				min     => MIN_LAST_NAME_LENGTH,
				max     => MAX_LAST_NAME_LENGTH,
				matches => qr/^[\w\-]+$/
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
				max      => MAX_WILL_YEAR
			}
		}
	});

	unless(length($params->{'last'} // '')) {
		Carp::carp("Value for 'last' is mandatory");
		return;
	}

	# Defence in depth: strip chars not matched by validation regex ([\w-] only;
	# the apostrophe was previously present here but is not in the validated set)
	$params->{'last'} =~ s/[^\w\-]//g;

	$self->{'wills'} ||= Genealogy::Wills::wills->new(no_entry => 1, no_fixate => 1, %{$self});

	Carp::croak("Can't open the wills database") unless defined($self->{'wills'});

	if(wantarray) {
		if(my $wills = $self->{'wills'}->selectall_hashref($params)) {
			$_->{'url'} = 'https://' . $_->{'url'} for @{$wills};
			Data::Reuse::fixate(@{$wills});
			return @{$wills};
		}
		return;
	}
	if(defined(my $will = $self->{'wills'}->fetchrow_hashref($params))) {
		$will->{'url'} = 'https://' . $will->{'url'};
		Data::Reuse::fixate(%{$will});
		return Return::Set::set_return($will, { 'type' => 'hashref', 'min' => 1 });
	}
	return;
}

=encoding utf-8

=head1 LIMITATIONS

=over 4

=item * B<C<::new()> with arguments is unsupported.>
C<Genealogy::Wills::new('Smith')> shifts C<'Smith'> into C<$class> and
attempts to bless into it. Only the no-argument form
C<Genealogy::Wills::new()> is partially handled (it defaults to
C<__PACKAGE__>). Always use the arrow form: C<< Genealogy::Wills->new() >>.

=item * B<Private methods are unenforced.>
There are currently no private helper methods in this module. If internal
helpers are added they should be marked with C<Sub::Private> (C<:Private>
attribute) to prevent accidental external use. C<Sub::Protected> should be
used for methods intended only for subclasses.

=item * B<Year upper bound is capped at load time.>
C<MAX_WILL_YEAR> is computed once when the module is first loaded. In the
unlikely event the module remains loaded across a year boundary the cap will
be one year stale.

=item * B<No full-text search.>
Searches are exact-match on the columns provided. There is no fuzzy or
phonetic matching (e.g. Soundex). Wildcard support depends on the
C<Database::Abstraction> layer.

=item * B<Single database source.>
The data comes from a single scraped source (the Kent Wills Transcript). It
does not cover wills from other archives.

=back

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 BUGS

=head1 SEE ALSO

The Kent Wills Transcript, L<https://freepages.rootsweb.com/~mrawson/genealogy/wills.html>

=head1 SUPPORT

This module is provided as-is without any warranty.

You can find documentation for this module with the perldoc command.

    perldoc Genealogy::Wills

You can also look for information at:

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

    [NAME, URL, DIRECTORY]

    WillRecord == [
        first  : NAME;
        last   : NAME;
        url    : URL;
        additional_fields : P(NAME x seq CHAR)
    ]

    SearchParams == [
        last   : NAME;
        first  : NAME;          -- optional
        middle : NAME;          -- optional
        town   : NAME;          -- optional
        year   : N              -- optional
    ]

    | last != empty  -- last name cannot be empty

    search: WillsDatabase x SearchParams -> P WillRecord

    For all db: WillsDatabase; params: SearchParams:
        params.last != empty =>
            search(db, params) = { r: WillRecord | r.last = params.last AND matches(r, params) }
        params.last = empty =>
            search(db, params) = empty

=head1 LICENSE AND COPYRIGHT

Copyright 2023-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut

1;
