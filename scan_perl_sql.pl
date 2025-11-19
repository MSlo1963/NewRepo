#!/usr/bin/env perl
use strict;
use warnings;
use PPI;
use File::Find;
use Getopt::Long;
use JSON;

my $dir = '.';
GetOptions('dir=s' => \$dir) or die "Usage: $0 --dir PATH\n";

my @files;
find(sub { push @files, $File::Find::name if -f && /\.pl$/ }, $dir);

# SQL verbs we'll use to determine the SQL type for the "name" field
my $sql_type_re = qr/\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b/i;

my $sql_re = qr/\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|FROM|WHERE|JOIN|INTO)\b/i;
my $dbi_re = qr/(?:->\s*(prepare|do|execute|selectall_arrayref|selectrow_array|selectrow_hashref|selectcol_arrayref|prepare_cached))/i;

# Variables to ignore when checking for missing declarations (common DBI vars / obvious non-SQL vars)
my %ignore_vars = map { $_ => 1 } ('$dbh', '$sth', '$_', '$self', '$0');

my %results;

for my $file (@files) {
    my $doc = PPI::Document->new($file);
    unless ($doc) {
        warn "Cannot parse $file\n";
        next;
    }

    my @found;

    # search quoted strings
    if (my $quotes = $doc->find('PPI::Token::Quote')) {
        for my $t (@$quotes) {
            my $s = $t->string || $t->content;
            if ($s =~ $sql_re) {
                my $line = eval { $t->line_number } // offset_to_line($doc->content, $t->location->[0] || 0);
                my $var  = find_assigned_variable($t);
                push @found, { type => 'string', line => $line, variable => (defined $var ? $var : undef), snippet => snippet($s) };
            }
        }
    }

    # search heredocs, with variable detection
    if (my $hds = $doc->find('PPI::Token::HereDoc')) {
        for my $h (@$hds) {
            my $s = $h->content || '';
            if ($s =~ $sql_re) {
                my $line = eval { $h->line_number } // offset_to_line($doc->content, $h->location->[0] || 0);
                my $var  = find_assigned_variable($h);
                push @found, { type => 'heredoc', line => $line, variable => (defined $var ? $var : undef), snippet => snippet($s) };
            }
        }
    }

    # search for DBI-like method calls in the whole file content and record line numbers
    my $content = $doc->content;
    while ($content =~ /$dbi_re/ig) {
        my $method = lc($1 // '');
        my $start_pos = $-[0] // 0;
        my $line = offset_to_line($content, $start_pos);
        push @found, { type => 'dbi_call', method => $method, line => $line, context => snippet_context($content, $start_pos, $+[0]) };
    }

    # Deduplicate: remove inline string findings (variable == undef) that also appear as quoted literals inside dbi_call contexts
    my @dbi_literals_norm;
    for my $f (@found) {
        next unless $f->{type} && $f->{type} eq 'dbi_call' && $f->{context};
        my $ctx = $f->{context};
        # extract quoted literals from context (handles '...' and "...")
        while ($ctx =~ /'([^']*)'|"([^"]*)"/g) {
            my $lit = defined $1 ? $1 : $2;
            push @dbi_literals_norm, normalize_for_match($lit) if defined $lit && $lit ne '';
        }
    }
    my %dbi_lits = map { $_ => 1 } @dbi_literals_norm;

    my @filtered;
    for my $f (@found) {
        if ($f->{type} && $f->{type} eq 'string' && !defined $f->{variable}) {
            # compare normalized snippet
            my $norm = normalize_for_match($f->{snippet});
            if ($norm ne '' && exists $dbi_lits{$norm}) {
                # skip this inline string because it is duplicated inside a dbi_call
                next;
            }
            # also skip if any dbi_call context contains the snippet as a substring (case-insensitive)
            my $found_in_context = 0;
            for my $g (@found) {
                next unless $g->{type} && $g->{type} eq 'dbi_call' && $g->{context};
                if (index(lc($g->{context}), lc($f->{snippet})) != -1) {
                    $found_in_context = 1;
                    last;
                }
            }
            next if $found_in_context;
        }
        push @filtered, $f;
    }

    # Add "name" for items where variable is not null:
    # format: <variable-without-sigil>_<line>_<SQLTYPE>
    for my $f (@filtered) {
        if (defined $f->{variable}) {
            my $var = $f->{variable} // '';
            # strip common sigils ($ @ % &) and surrounding braces if present
            $var =~ s/^[\$\@\%\&]+//;
            $var =~ s/^\{(.*)\}$/$1/;
            my $line = defined $f->{line} ? $f->{line} : '?';
            my $text = $f->{snippet} // $f->{context} // '';
            my $type = 'UNKNOWN';
            if ($text =~ /$sql_type_re/) {
                $type = uc($1);
            }
            $f->{name} = sprintf("%s_%s_%s", $var, $line, $type);
        }
    }

    # Collect declared variables from string/heredoc findings
    my %declared_vars;
    for my $f (@filtered) {
        if (($f->{type} eq 'string' || $f->{type} eq 'heredoc') && defined $f->{variable}) {
            $declared_vars{$f->{variable}} = 1;
        }
    }

    # Scan dbi_call contexts for $variables and log missing ones (not declared as string/heredoc)
    # We append 'missing_variable' findings to @filtered (one per variable per file).
    my %missing_seen;
    for my $f (@filtered) {
        next unless $f->{type} && $f->{type} eq 'dbi_call' && $f->{context};
        my $ctx = $f->{context};
        # find $var occurrences (simple heuristic)
        while ($ctx =~ /(\$[A-Za-z_]\w*)/g) {
            my $var = $1;
            next if exists $ignore_vars{$var};
            next if exists $declared_vars{$var};
            next if exists $missing_seen{$var}; # avoid duplicates
            # record missing variable
            push @filtered, {
                type => 'missing_variable',
                variable => $var,
                used_in_line => $f->{line},
                context => $f->{context},
                note => "variable used in dbi_call but no string/heredoc declaration found in this file"
            };
            $missing_seen{$var} = 1;
        }
    }

    if (@filtered) {
        $results{$file} = \@filtered;
    }
}

print JSON->new->pretty->encode(\%results);

# helpers

sub snippet {
    my ($s) = @_;
    $s =~ s/\s+/ /g;
    $s = substr($s, 0, 200) . (length($s) > 200 ? '...' : '');
    $s =~ s/"/'/g;
    return $s;
}

sub snippet_context {
    my ($c, $start, $end) = @_;
    my $from = $start - 40; $from = 0 if $from < 0;
    my $to = $end + 40; $to = length($c) if $to > length($c);
    my $sn = substr($c, $from, $to - $from);
    $sn =~ s/\s+/ /g;
    $sn =~ s/"/'/g;
    return substr($sn, 0, 200) . (length($sn) > 200 ? '...' : '');
}

sub offset_to_line {
    my ($content, $pos) = @_;
    $pos = 0 unless defined $pos && $pos >= 0;
    # count newlines before pos; 1-based lines
    my $pre = substr($content, 0, $pos);
    my $count = () = $pre =~ /\n/g;
    return $count + 1;
}

# Try to detect if the given token is the RHS of an assignment and return the LHS variable name (e.g. "$sql").
# Returns undef if none detected.
sub find_assigned_variable {
    my ($token) = @_;
    return undef unless $token && eval { $token->can('previous_token') };

    # Walk tokens backwards looking for an '=' which appears before statement terminator (';')
    my $tok = $token;
    my $eq_tok;
    while (defined($tok = $tok->previous_token)) {
        my $c = defined $tok->content ? $tok->content : '';
        last if $c eq ';';           # stop at statement boundary
        last if $c eq '{' or $c eq '}'; # safety stop
        if ($c eq '=') {
            $eq_tok = $tok;
            last;
        }
    }

    return undef unless $eq_tok;

    # From the '=' token, walk further backward to find the variable symbol
    my $t2 = $eq_tok;
    while (defined($t2 = $t2->previous_token)) {
        # prefer a symbol token
        if (ref($t2) && $t2->isa('PPI::Token::Symbol')) {
            return $t2->content;
        }
        # handle declarations like: my $sql = "...";
        if (ref($t2) && $t2->isa('PPI::Token::Word') && $t2->content =~ /^(my|our|local)$/) {
            # find symbol after the declaration word (move forward from this token)
            my $next = $t2;
            while (defined($next = $next->next_token)) {
                return undef if $next->content eq ';'; # nothing found in this declaration
                if (ref($next) && $next->isa('PPI::Token::Symbol')) {
                    return $next->content;
                }
            }
            last;
        }
        # stop if we reach a comma (multiple assignments) to avoid grabbing unrelated symbols
        last if $t2->content eq ',';
    }

    return undef;
}

# Normalize a string for fuzzy equality: lowercase, collapse whitespace, strip surrounding punctuation
sub normalize_for_match {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\s+/ /g;
    $s = lc $s;
    # remove leading/trailing punctuation that often wraps SQL in code contexts
    $s =~ s/^[\(\[\"']+//;
    $s =~ s/[\)\]\"']+$//;
    return $s;
}
