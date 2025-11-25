use strict;
use warnings;
use DBI;
use FindBin;
use lib "$FindBin::Bin/..";
use SQL::Separated;

# Connect DB (pas aan naar jouw DB)
my $dbh = DBI->connect($ENV{DSN} // 'dbi:Pg:dbname=test', $ENV{DB_USER}//'', $ENV{DB_PASS}//'', { RaiseError=>1, AutoCommit=>1 });

my $store = SQL::Separated->new();
# laad statements (JSONL bestand)
$store->load_from_jsonl('examples/sql_statements.jsonl');

# veilige identifier substitution: alleen letters/_/digits
my $idents = { table => 'users' };

# voorbeeld 1: één row ophalen met named param
my $rows = $store->fetch_all($dbh, 'user.get_by_id', { idents => $idents, binds => { id => 42 } });
foreach my $r (@$rows) {
    print "User: $r->{username} <$r->{email}>\n";
}

# voorbeeld 2: pattern search
my $rows2 = $store->fetch_all($dbh, 'user.search', { idents => $idents, binds => { pattern => '%smith%' } });
print "Found ", scalar(@$rows2), " rows\n";

# Voor statements die niet select zijn:
my $sth = $store->execute($dbh, 'user.update_last_login', { idents => $idents, binds => { id => 42, ts => '2025-11-24' } });
print "Updated rows: ", $sth->rows, "\n";

$dbh->disconnect;
