# NAME

Genealogy::Wills - Lookup in a database of wills

# VERSION

Version 0.05

# SYNOPSIS

    # See https://freepages.rootsweb.com/~mrawson/genealogy/wills.html
    use Genealogy::Wills;
    my $wills = Genealogy::Wills->new();
    # ...

# SUBROUTINES/METHODS

## new

Creates a Genealogy::Wills object.

Takes two optional arguments:
	directory: that is the directory containing obituaries.sql
	logger: an object to send log messages to

## search

    my $wills = Genealogy::Wills->new();

    # Returns an array of hashrefs
    my @smiths = $wills->search(last => 'Smith');       # You must at least define the last name to search for

    print $smiths[0]->{'first'}, "\n";

# AUTHOR

Nigel Horne, `<njh at bandsman.co.uk>`

# BUGS

# SEE ALSO

The Kent Wills Transcript, [https://freepages.rootsweb.com/~mrawson/genealogy/wills.html](https://freepages.rootsweb.com/~mrawson/genealogy/wills.html)

# SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Genealogy::Wills

You can also look for information at:

- MetaCPAN

    [https://metacpan.org/release/Genealogy-Wills](https://metacpan.org/release/Genealogy-Wills)

- RT: CPAN's request tracker

    [https://rt.cpan.org/NoAuth/Bugs.html?Dist=Genealogy-Wills](https://rt.cpan.org/NoAuth/Bugs.html?Dist=Genealogy-Wills)

- CPAN Testers' Matrix

    [http://matrix.cpantesters.org/?dist=Genealogy-Wills](http://matrix.cpantesters.org/?dist=Genealogy-Wills)

- CPAN Testers Dependencies

    [http://deps.cpantesters.org/?module=Genealogy::Wills](http://deps.cpantesters.org/?module=Genealogy::Wills)

# LICENSE AND COPYRIGHT

Copyright 2023-2024 Nigel Horne.

This program is released under the following licence: GPL2
