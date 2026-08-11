# NAME

Genealogy::Wills - Lookup in a database of wills

# VERSION

Version 0.10

# DESCRIPTION

This module provides a convenient interface to search through a database of historical wills,
primarily focused on the Kent Wills Transcript.
It handles database connections, caching, and result formatting.

\- Results are cached for 1 day by default
\- Database connections are lazy-loaded
\- Large result sets may consume significant memory

# SYNOPSIS

    # See https://freepages.rootsweb.com/~mrawson/genealogy/wills.html
    use Genealogy::Wills;
    my $wills = Genealogy::Wills->new();
    # ...

# SUBROUTINES/METHODS

## new

Creates a `Genealogy::Wills` object.

Takes up to three optional arguments as a hash, hashref, or key-value pairs.
Returns the new object, or `undef` if the directory is invalid.

- `config_file`

    Path to a configuration file (`YAML`, `XML`, `INI`, etc.) whose top-level
    key matching the class name supplies default parameters. Environment variables
    of the form `ClassName__key` override file values.
    Croaks if the path is specified but the file does not exist or is not readable.

- `directory`

    Directory containing `wills.sql`.
    If not given, uses the module's own data directory (`lib/Genealogy/Wills/data/`).

- `logger`

    An object with `info()` and `error()` methods; used by the underlying
    `Database::Abstraction` layer for diagnostics.

### EXAMPLE

    # Minimal - uses the bundled database
    my $wills = Genealogy::Wills->new();

    # Explicit directory
    my $wills = Genealogy::Wills->new(directory => '/data/wills');

    # From a YAML config file
    my $wills = Genealogy::Wills->new(config_file => '/etc/wills.yml');

### API SPECIFICATION

    # Input (all optional)
    {
        config_file => Str,     # readable file path
        directory   => Str,     # readable directory path
        logger      => Object,  # must implement info() and error()
    }

    # Returns
    Genealogy::Wills object, or undef if directory is invalid.

### MESSAGES

    Can't load configuration from <path>
        config_file was specified but the path is missing or unreadable.
        Resolution: verify path and permissions.

    Logger must be an object with info() and error() methods
        logger does not satisfy the required interface.
        Resolution: pass a compatible logger (e.g. Log::Log4perl).

    Genealogy::Wills: <dir> is not a directory
        The resolved directory does not exist or is not readable.
        Resolution: verify the path; rebuild the DB with bin/create_db.PL.

## search

Search the wills database.

`last` (last name) is mandatory and must be a non-empty string of word
characters (`\w`) and hyphens only.
Croaks immediately if called with no arguments at all.

In list context returns an array of hashrefs (empty list when nothing matches).
In scalar context returns a single hashref wrapped in `Return::Set` (undef
when nothing matches).
Every returned hashref has `first`, `last`, `town`, `year`, and `url`
fields; `url` has `https://` prepended.

### EXAMPLE

    my $wills = Genealogy::Wills->new();

    # All Smiths
    my @smiths = $wills->search(last => 'Smith');

    # Short form: single string is treated as the last name
    my @smiths = $wills->search('Smith');

    # Multi-field search
    my @joneses = $wills->search({ first => 'Mary', last => 'Jones', year => 1750 });

    print $smiths[0]->{'first'}, ' ', $smiths[0]->{'url'}, "\n";

### API SPECIFICATION

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

### MESSAGES

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

### PSEUDOCODE

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

# LIMITATIONS

- **`::new()` with arguments is unsupported.**
`Genealogy::Wills::new('Smith')` shifts `'Smith'` into `$class` and
attempts to bless into it. Only the no-argument form
`Genealogy::Wills::new()` is partially handled (it defaults to
`__PACKAGE__`). Always use the arrow form: `Genealogy::Wills->new()`.
- **Private methods are unenforced.**
There are currently no private helper methods in this module. If internal
helpers are added they should be marked with `Sub::Private` (`:Private`
attribute) to prevent accidental external use. `Sub::Protected` should be
used for methods intended only for subclasses.
- **Year upper bound is capped at load time.**
`MAX_WILL_YEAR` is computed once when the module is first loaded. In the
unlikely event the module remains loaded across a year boundary the cap will
be one year stale.
- **No full-text search.**
Searches are exact-match on the columns provided. There is no fuzzy or
phonetic matching (e.g. Soundex). Wildcard support depends on the
`Database::Abstraction` layer.
- **Single database source.**
The data comes from a single scraped source (the Kent Wills Transcript). It
does not cover wills from other archives.

# AUTHOR

Nigel Horne, `<njh at nigelhorne.com>`

# BUGS

# SEE ALSO

The Kent Wills Transcript, [https://freepages.rootsweb.com/~mrawson/genealogy/wills.html](https://freepages.rootsweb.com/~mrawson/genealogy/wills.html)

# SUPPORT

This module is provided as-is without any warranty.

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

# FORMAL SPECIFICATION

## search

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

# LICENSE AND COPYRIGHT

Copyright 2023-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.
