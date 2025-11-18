use strict;
use warnings;
use JSON::PP;

my $input_file = shift or die "Usage: $0 input.pl\n";
open my $in, '<', $input_file or die "Cannot open $input_file: $!";

my $jsonl_file = $input_file;
$jsonl_file =~ s/\.pl$/.sql.jsonl/;
open my $out, '>', $jsonl_file or die "Cannot write $jsonl_file: $!";

my $script_name = $input_file;
my $in_sql = 0;
my $sql = '';
my $delimiter = '';
my $start_line = 0;

my $line_num = 0;
while (my $line = <$in>) {
    $line_num++;
    # Match start of SQL assignment
    if ($line =~ /^\s*(?:my\s+)?\$[a-zA-Z0-9_]+\s*=\s*(["'])(.*)/) {
        $in_sql = 1;
        $delimiter = $1;
        $sql = $2;
        $start_line = $line_num;
        # If ends on same line
        if ($sql =~ /(.*)$delimiter;/) {
            $sql = $1;
            write_jsonl($script_name, $start_line, $sql, $out);
            $in_sql = 0;
            $sql = '';
        }
        next;
    }
    # Match qq{} or qq()
    if ($line =~ /^\s*(?:my\s+)?\$[a-zA-Z0-9_]+\s*=\s*qq([\{\(])/) {
        $in_sql = 1;
        $delimiter = $1 eq '{' ? '}' : ')';
        $sql = '';
        $start_line = $line_num;
        next;
    }
    # Match heredoc
    if ($line =~ /^\s*(?:my\s+)?\$[a-zA-Z0-9_]+\s*=\s*<<(\w+)/) {
        $in_sql = 1;
        $delimiter = $1;
        $sql = '';
        $start_line = $line_num;
        next;
    }
    # Collect lines inside SQL assignment
    if ($in_sql) {
        # End of quoted string
        if ($delimiter eq '"' || $delimiter eq "'") {
            if ($line =~ /(.*)$delimiter;/) {
                $sql .= $1;
                write_jsonl($script_name, $start_line, $sql, $out);
                $in_sql = 0;
                $sql = '';
            } else {
                $sql .= $line;
            }
        }
        # End of qq{} or qq()
        elsif ($delimiter eq '}' || $delimiter eq ')') {
            if ($line =~ /(.*)$delimiter;/) {
                $sql .= $1;
                write_jsonl($script_name, $start_line, $sql, $out);
                $in_sql = 0;
                $sql = '';
            } else {
                $sql .= $line;
            }
        }
        # End of heredoc
        else {
            if ($line =~ /^$delimiter\s*$/) {
                write_jsonl($script_name, $start_line, $sql, $out);
                $in_sql = 0;
                $sql = '';
            } else {
                $sql .= $line;
            }
        }
    }
}

close $in;
close $out;

sub write_jsonl {
    my ($name, $line, $sql, $fh) = @_;
    my $json = JSON::PP->new->encode({
        name => $name,
        line => $line,
        sql  => $sql
    });
    print $fh $json, "\n";
}
