package Genealogy::Wills;

use warnings;
use strict;
use Carp;
use File::Spec;
use Module::Info;
use Genealogy::ObituaryDailyTimes::DB;
use Genealogy::ObituaryDailyTimes::DB::obituaries;

=head1 NAME

Genealogy::Wills - Lookup in a Wills database

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    # See https://freepages.rootsweb.com/~mrawson/genealogy/wills.html
    use Genealogy::ObituaryDailyTimes;
    my $info = Genealogy::ObituaryDailyTimes->new();
    # ...

=head1 SUBROUTINES/METHODS

=head2 new

Creates a Genealogy::ObituaryDailyTimes object.

Takes an optional argument, directory, that is the directory containing obituaries.sql.

=cut

sub new {
	my($proto, %param) = @_;
	my $class = ref($proto) || $proto;

	# Use Genealogy::ObituaryDailyTimes->new, not Genealogy::ObituaryDailyTimes::new
	return unless($class);

	my $directory = $param{'directory'} || Module::Info->new_from_loaded(__PACKAGE__)->file();
	$directory =~ s/\.pm$//;

	Genealogy::ObituaryDailyTimes::DB::init(directory => File::Spec->catfile($directory, 'database'), %param);
	return bless { }, $class;
}

=head2 search

    my $obits = Genealogy::ObituaryDailyTimes->new();

    # Returns an array of hashrefs
    my @smiths = $obits->search(last => 'Smith');	# You must at least define the last name to search for

    print $smiths[0]->{'first'}, "\n";

=cut

sub search {
	my $self = shift;

	my %params = (ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;

	if(!defined($params{'last'})) {
		Carp::carp("Value for 'last' is mandatory");
		return;
	}

	$self->{'obituaries'} ||= Genealogy::ObituaryDailyTimes::DB::obituaries->new(no_entry => 1);

	if(!defined($self->{'obituaries'})) {
		Carp::croak("Can't open the obituaries database");
	}

	if(wantarray) {
		my @obituaries = @{$self->{'obituaries'}->selectall_hashref(\%params)};
		foreach my $obit(@obituaries) {
			$obit->{'url'} = _create_url($obit);
		}
		return @obituaries;
	}
	my $obit = $self->{'obituaries'}->fetchrow_hashref(\%params);
	$obit->{'url'} = _create_url($obit);
	return $obit;
}

sub _create_url {
	my $obit = shift;
	my $source = $obit->{'source'};
	my $page = $obit->{'page'};

	if($source eq 'M') {
		return "https://mlarchives.rootsweb.com/listindexes/emails?listname=gen-obit&page=$page";
	}
	if($source eq 'F') {
		return "https://www.freelists.org/post/obitdailytimes/Obituary-Daily-Times-$page";
	}
	Carp::croak(__PACKAGE__, ": Invalid source, '$source'");
}

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 BUGS

=head1 SEE ALSO

The Obituary Daily Times, L<https://sites.rootsweb.com/~obituary/>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Genealogy::ObituaryDailyTimes

You can also look for information at:

=over 4

=item * MetaCPAN

L<https://metacpan.org/release/Genealogy-ObituaryDailyTimes>

=item * RT: CPAN's request tracker

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Genealogy-ObituaryDailyTimes>

=item * CPANTS

L<http://cpants.cpanauthors.org/dist/Genealogy-ObituaryDailyTimes>

=item * CPAN Testers' Matrix

L<http://matrix.cpantesters.org/?dist=Genealogy-ObituaryDailyTimes>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Genealogy-ObituaryDailyTimes>

=item * CPAN Testers Dependencies

L<http://deps.cpantesters.org/?module=Genealogy::ObituaryDailyTimes>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2023 Nigel Horne.

This program is released under the following licence: GPL2

=cut

1;
