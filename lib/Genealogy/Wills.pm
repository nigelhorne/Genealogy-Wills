package Genealogy::Wills;

use strict;
use warnings;
use autodie qw(:all);
use Carp;
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

Creates a Genealogy::Wills object.

Takes three optional arguments,
which can be hash, hash-ref or key-value pairs.

=over 4

=item * C<config_file>

Points to a configuration file which contains the parameters to C<new()>.
The file can be in any common format,
including C<YAML>, C<XML>, and C<INI>.
This allows the parameters to be set at run time.
Croaks if the path is specified but the file does not exist or is not readable.

=item * C<directory>

That is the directory containing wills.sql.
If not given, uses the module's own data directory.

=item * C<logger>

An object to send log messages to

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

	if(!defined($class)) {
		if((scalar keys %{$params}) > 0) {
			# Using Genealogy::Wills::new(), not Genealogy::Wills->new()
			carp(__PACKAGE__, ' use ->new() not ::new() to instantiate');
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
		carp(__PACKAGE__, ': ', $params->{'directory'}, ' is not a directory');
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

C<last> (last name) is a mandatory parameter.
It must be a non-empty string containing only word characters (C<\w>) and hyphens.
Croaks if called with no arguments at all.

Returns a list of hash references in list context,
or a single hash reference in scalar context.
Returns nothing if no records match.

Each record includes a C<url> field with the C<https://> scheme prepended.

    my $wills = Genealogy::Wills->new();

    my @smiths = $wills->search(last => 'Smith');
    my @joneses = $wills->search({ first => 'Mary', last => 'Jones', year => 1750 });

    print $smiths[0]->{'first'}, "\n";

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
				max      => 2025
			}
		}
	});

	unless(length($params->{'last'} // '')) {
		Carp::carp("Value for 'last' is mandatory");
		return;
	}

	# Defence in depth: strip chars not matched by validation regex
	$params->{'last'} =~ s/[^\w\-']//g;

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
}

=encoding utf-8

=head1 FORMAL SPECIFICATION

    [NAME, URL, DIRECTORY]

    WillRecord == [
        first: NAME;
        last: NAME;
        url: URL;
        additional_fields: ℙ(NAME × seq CHAR)
    ]

    WillsDatabase == [
        directory: DIRECTORY;
        cache_duration: ℕ;
        logger: LOGGER
    ]

    SearchParams == [
        last: NAME;
        first: NAME;
        optional_params: ℙ(NAME × seq CHAR)
    ]

    │ last ≠ ∅  -- last name cannot be empty
    │ |last| > 0  -- last name must have positive length

    search: WillsDatabase × SearchParams → ℙ WillRecord

    ∀ db: WillsDatabase; params: SearchParams •
        params.last ≠ ∅ ⇒
        search(db, params) = {r: WillRecord | r.last = params.last ∧ matches(r, params)}

    ∀ db: WillsDatabase; params: SearchParams •
        params.last = ∅ ⇒
        search(db, params) = ∅

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

=head1 LICENSE AND COPYRIGHT

Copyright 2023-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut

1;
