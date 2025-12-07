#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP;
use Encode qw(encode_utf8);

# Usage:
#   convert_jsonl_to_yaml.pl input.jsonl > output.yml
#   or: cat input.jsonl | convert_jsonl_to_yaml.pl - > output.yml
#
# The script expects JSON Lines where each line is a JSON object with:
#   { "name": "...", "sql": "..." }
#
# It prints YAML sequence items to STDOUT using the structure you specified.

my $infile = shift // '-';

my $fh;
if ($infile eq '-') {
    $fh = *STDIN;
} else {
    open($fh, '<', $infile) or die "Can't open '$infile': $!";
}

my $decoder = JSON::PP->new->utf8->allow_nonref;

my @items;
while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*$/;
    my $obj;
    eval { $obj = $decoder->decode($line) };
    if ($@) {
        warn "Skipping invalid JSON line: $@\n";
        next;
    }
    push @items, $obj;
}

# Helper: escape double quotes for YAML double-quoted scalars
sub yq {
    my ($s) = @_;
    $s //= '';
    $s =~ s/"/\\"/g;
    return $s;
}

# List of multi-word and single-word SQL keywords to format/uppercase
my @keywords = (
    'group by', 'order by', 'left join', 'right join', 'inner join',
    'select', 'from', 'where', 'having', 'join', 'on', 'and', 'or', 'limit', 'as'
);

sub pretty_sql {
    my ($sql) = @_;
    return '' unless defined $sql;

    # Normalize whitespace
    $sql =~ s/\r/\n/g;
    $sql =~ s/\n+/ /g;
    $sql =~ s/\s+/ /g;
    $sql =~ s/^\s+|\s+$//g;

    # Uppercase known keywords (longer phrases first)
    foreach my $kw (sort { length($b) <=> length($a) } @keywords) {
        my $pattern = $kw;
        $pattern =~ s/\s+/\\s+/g; # allow flexible spacing
        $sql =~ s/\b($pattern)\b/uc($1)/ig;
    }

    # Insert newlines before major clauses (except SELECT start)
    $sql =~ s/\s+\b(FROM|WHERE|GROUP BY|ORDER BY|HAVING|LIMIT|ON|JOIN|LEFT JOIN|RIGHT JOIN|INNER JOIN)\b/ "\n$1"/ige;

    # Break SELECT column list into separate lines if possible
    if ($sql =~ /SELECT\s+(.*?)\s+FROM\s+/s) {
        my $cols = $1;
        my $after = $'; # Rest after matched portion (not used except to rebuild)
        my $before_from = $&; # matched text SELECT ... FROM (we'll rebuild)
        # Split on commas that are not inside parentheses (simple approach)
        my @parts;
        {
            my $tmp = $cols;
            my @cells;
            my $cur = '';
            my $depth = 0;
            while ($tmp =~ /(.)/gs) {
                my $ch = $1;
                if ($ch eq '(') { $depth++ }
                elsif ($ch eq ')') { $depth-- if $depth>0 }
                if ($ch eq ',' && $depth == 0) {
                    push @cells, $cur;
                    $cur = '';
                } else {
                    $cur .= $ch;
                }
            }
            push @cells, $cur if length($cur) || !@cells;
            @parts = map { s/^\s+|\s+$//g; $_ } @cells;
        }
        if (@parts > 1) {
            my $cols_block = join(",\n  ", @parts);
            # rebuild SQL replacing the original SELECT ... FROM ... with separated lines
            $sql =~ s/SELECT\s+(.*?)\s+FROM/SELECT\n  $cols_block\nFROM/s;
        }
    }

    # Break AND/OR into separate indented lines inside WHERE (and other clauses)
    $sql =~ s/\s+\bAND\b\s+/\n  AND /ig;
    $sql =~ s/\s+\bOR\b\s+/\n  OR /ig;

    # Tidy: remove duplicated spaces around commas / parentheses
    $sql =~ s/\s+,/,/g;
    $sql =~ s/,\s+/, /g;
    $sql =~ s/\s+\(/ (/g;
    $sql =~ s/\(\s+/\(/g;
    $sql =~ s/\s+\)/)/g;

    # Trim each line
    my @lines = map { s/^\s+|\s+$//g; $_ } split(/\n/, $sql);

    return join("\n", @lines);
}

# Process each item and print YAML
# Top-level: sequence of items
foreach my $obj (@items) {
    my $name = defined $obj->{name} ? $obj->{name} : '';
    my $sql  = defined $obj->{sql}  ? $obj->{sql}  : '';

    # Find double-underscore tokens in original SQL in order of appearance
    my @found;
    {
        my $s = $sql;
        while ($s =~ /__(.+?)__/g) {
            push @found, $1;
        }
    }
    my %seen;
    my @ordered = grep { !$seen{$_}++ } @found;  # unique, preserve order

    # placeholders and bind_values
    my %placeholders;
    my @bind_values;
    foreach my $tok (@ordered) {
        if ($tok eq 'ENTITY') {
            $placeholders{ENTITY} = "BR";
        } else {
            push @bind_values, "__$tok__";
        }
    }

    # Replace non-placeholder __<text>__ tokens with ?
    $sql =~ s/__(.+?)__/ $1 eq 'ENTITY' ? "__$1__" : "?" /ge;

    # Pretty-print SQL
    my $pretty = pretty_sql($sql);

    # Output YAML for this item
    # - id: name
    #   sql: |
    #     <lines>
    #   meta:
    #     db: "rep"
    #     placeholders: { ... } or indented mapping
    #     bind_values:
    #       - "__myf1__"
    #       - "__myf2__"
    print "- id: $name\n";
    print "  sql: |\n";
    for my $line (split /\n/, $pretty) {
        # indent SQL block lines by four spaces (so they align as in examples)
        print "    $line\n";
    }
    print "  meta:\n";
    print "    db: \"rep\"\n";

    # placeholders block
    if (%placeholders) {
        print "    placeholders:\n";
        foreach my $k (sort keys %placeholders) {
            my $v = $placeholders{$k};
            print "      $k: \"" . yq($v) . "\"\n";
        }
    } else {
        print "    placeholders: {}\n";
    }

    # bind_values block
    if (@bind_values) {
        print "    bind_values:\n";
        foreach my $bv (@bind_values) {
            print "      - \"" . yq($bv) . "\"\n";
        }
    } else {
        print "    bind_values: []\n";
    }

    print "\n";
}

exit 0;
