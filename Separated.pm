package SQL::Separated;
use strict;
use warnings;
use JSON::MaybeXS;
use Carp;
use Scalar::Util qw(looks_like_number);

# Lightweight library to separate SQL from PL code.
# - load SQL statements from JSON, JSONL, or a directory of .sql files
# - support :named placeholders -> converted to ? with bind order
# - support safe identifier substitution for table/column names via {{ident}}

sub new {
    my ($class, %args) = @_;
    my $self = {
        statements => {},    # id => { sql => "...", meta => {...} }
        json       => JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1),
        %args,
    };
    bless $self, $class;
    return $self;
}

# Load all statements from a JSON file (single object mapping id -> { sql, meta? })
sub load_from_json {
    my ($self, $path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or croak "Cannot open $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    my $data = $self->{json}->decode($text);
    foreach my $id (keys %$data) {
        my $entry = $data->{$id};
        croak "Entry $id missing sql" unless exists $entry->{sql};
        $self->{statements}{$id} = { sql => $entry->{sql}, meta => $entry->{meta} // {} };
    }
    return 1;
}

# Load from JSONL: each line is {"id":"ns.query","sql":"SELECT ...","meta":{...}}
sub load_from_jsonl {
    my ($self, $path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or croak "Cannot open $path: $!";
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        my $obj = $self->{json}->decode($line);
        croak "JSONL entry missing id or sql" unless $obj->{id} && $obj->{sql};
        $self->{statements}{$obj->{id}} = { sql => $obj->{sql}, meta => $obj->{meta} // {} };
    }
    close $fh;
    return 1;
}

# Load from directory: each file name (without ext) is id, file contains SQL.
# Optionally allow "id.sql" or "namespace.id.sql".
sub load_from_dir {
    my ($self, $dir) = @_;
    opendir my $dh, $dir or croak "Cannot read dir $dir: $!";
    while (my $f = readdir $dh) {
        next if $f =~ /^\./;
        next unless $f =~ /\.sql$/i;
        my $id = $f;
        $id =~ s/\.sql$//i;
        open my $fh, '<:encoding(UTF-8)', "$dir/$f" or croak "Cannot open $dir/$f: $!";
        local $/;
        my $sql = <$fh>;
        close $fh;
        $self->{statements}{$id} = { sql => $sql, meta => {} };
    }
    closedir $dh;
    return 1;
}

# Return raw SQL by id (croak if not found)
sub get_sql {
    my ($self, $id) = @_;
    croak "No id provided" unless $id;
    my $entry = $self->{statements}{$id} or croak "SQL id '$id' not found";
    return $entry->{sql}, $entry->{meta};
}

# Replace safe identifiers in SQL template.
# Placeholders in SQL look like {{table}} or {{col}}. Only allow identifiers that match /^\w+$/ to avoid injection.
sub apply_identifiers {
    my ($self, $sql, $idents) = @_;
    return $sql unless $idents && %$idents;
    $sql =~ s/\{\{\s*([A-Za-z_]\w*)\s*\}\}/
        exists $idents->{$1} ? do {
            my $val = $idents->{$1};
            croak "Unsafe identifier for $1" unless defined $val && $val =~ /^[A-Za-z_]\w*$/;
            $val;
        } : croak("Identifier {{$1}} not provided")
    /eg;
    return $sql;
}

# Convert :name placeholders to ? and return (sql_with_qmarks, bind_order_arrayref)
# Keeps duplicates (if :id used twice, id appears twice in bind_order).
# Note: simplistic - will match :name where name is [A-Za-z_]\w*
sub _compile_named_placeholders {
    my ($self, $sql) = @_;
    my @names = ();
    my $compiled = $sql;
    # Avoid converting :: (postgres type cast) by a simple rule: ignore '::' occurrences
    # We'll do a regex that finds :name not preceded or followed by ':'
    $compiled =~ s/(?<!:):([A-Za-z_]\w*)/push @names, $1, '?'/eg;
    # After substitution the string contains '?' in place of each :name,
    # but above substitution produced appended '?', so we need to clean up: the s/// replacement inserted '?', but my method above isn't perfect.
    # Simpler approach: build by scanning
    if (!@names) {
        # If none matched, just return unchanged
        return ($sql, []);
    }
    # Re-scan to construct sql replacing :name -> ? but ignoring :: sequences:
    my $out = '';
    pos($sql) = 0;
    while ($sql =~ /(::)|:([A-Za-z_]\w*)/g) {
        my $mstart = $-[0];
        my $mend = $+[0];
        $out .= substr($sql, pos($sql) ? pos($sql) - ($mend - $mstart) : 0, $mstart - (pos($sql) ? pos($sql) - ($mend - $mstart) : 0));
        if (defined $1) {
            $out .= '::'; # keep postgres cast
        } else {
            push @names, $2;
            $out .= '?';
        }
        pos($sql) = $mend;
    }
    # Append remaining tail
    my $last = pos($sql) // 0;
    $out .= substr($sql, $last);
    return ($out, \@names);
}

# Prepare a DBI statement for given id, with identifiers applied and named binds converted.
# Returns prepared $sth and arrayref of bind keys in order (names), so caller can bind.
sub prepare_statement {
    my ($self, $dbh, $id, $params_ident) = @_;
    my ($sql, $meta) = $self->get_sql($id);
    my $idents = $params_ident->{idents} // {};
    $sql = $self->apply_identifiers($sql, $idents);
    # Convert named placeholders to '?' and get bind order
    my @names;
    # Simple implementation: find :name occurrences ignoring ::.
    my $s = $sql;
    @names = ();
    my $out = '';
    my $pos = 0;
    while ($s =~ /(::)|:([A-Za-z_]\w*)/g) {
        my $m = $&;
        my $start = $-[0];
        $out .= substr($s, $pos, $start - $pos);
        if (defined $1) {
            $out .= '::';
        } else {
            push @names, $2;
            $out .= '?';
        }
        $pos = $+[0];
    }
    $out .= substr($s, $pos);
    my $sth = $dbh->prepare($out);
    return ($sth, \@names, $meta);
}

# Helper to build bind-values arrayref from named params hashref and bind_order arrayref.
sub build_bind_values {
    my ($self, $bind_order, $named_params) = @_;
    my @binds;
    foreach my $k (@$bind_order) {
        croak "Missing bind value for :$k" unless exists $named_params->{$k};
        push @binds, $named_params->{$k};
    }
    return \@binds;
}

# Execute a statement by id: does prepare, bind and execute, returns $sth
# params: { idents => {table=>'t'}, binds => { id => 123, name => 'x' } }
sub execute {
    my ($self, $dbh, $id, $params) = @_;
    $params //= {};
    my ($sth, $bind_order, $meta) = $self->prepare_statement($dbh, $id, $params);
    my $binds = $self->build_bind_values($bind_order, $params->{binds} // {});
    $sth->execute(@$binds);
    return $sth;
}

# Convenience: fetch all rows as arrayref of hashrefs
sub fetch_all {
    my ($self, $dbh, $id, $params) = @_;
    my $sth = $self->execute($dbh, $id, $params);
    my $rows = $sth->fetchall_arrayref({});
    $sth->finish;
    return $rows;
}

# Add/replace a statement at runtime
sub add_statement {
    my ($self, $id, $sql, $meta) = @_;
    croak "id and sql required" unless $id && $sql;
    $self->{statements}{$id} = { sql => $sql, meta => $meta // {} };
    return 1;
}

1;
__END__

# Caveats & notes:
# - This module uses a simple parser for :name placeholders and keeps :: (Postgres casts).
# - For complex SQL or edge cases, adapt regexes or use a proper SQL tokenizer.
# - Always prefer using bound values (not interpolated strings) for values. Identifiers are allowed only when they pass a strict regex.
