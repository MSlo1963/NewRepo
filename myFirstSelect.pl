
#!/usr/bin/perl
use strict;
use warnings;
use DBI;

# Connection parameters
my $dsn = 'DBI:Sybase:server=YOUR_SERVER;database=YOUR_DATABASE';
my $username = 'YOUR_USERNAME';
my $password = 'YOUR_PASSWORD';

# Connect to Sybase
my $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 1, PrintError => 0 })
    or die "Cannot connect: $DBI::errstr";

# Prepare and execute SELECT query
my $sql = 'SELECT * FROM your_table';
my $sth = $dbh->prepare($sql);
$sth->execute();

# Fetch and print results
while (my @row = $sth->fetchrow_array) {
    print join("\t", @row), "\n";
}

# Clean up
$sth->finish;
$dbh->disconnect;
