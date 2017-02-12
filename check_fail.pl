use Modern::Perl;

use DBI;
use DBD::Pg qw(:pg_types);


my $dbh = DBI->connect("dbi:Pg:dbname=bunnings", "", "",
	{RaiseError => 1, PrintError => 0, ShowErrorStatement => 1});

my $q_sql = "SELECT product_number FROM product WHERE product_number = ?";
my $q = $dbh->prepare($q_sql);


while(<>) {
	my ($id) = /^Parsing \S+_p(\d+) /;
	my ($file) = /^Parsing (\S+)/;
	next unless $id;

	$q->execute($id);
	my $ary_ref = $q->fetchrow_arrayref;

	# $ary_ref will be undef if there are no (more) rows to return
	say $file unless defined $ary_ref;
}
