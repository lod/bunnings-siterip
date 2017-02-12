#!/usr/bin/perl

use Modern::Perl;
use HTML::Tree;

use autodie;
use Carp;
use Try::Tiny;
use Data::Dump;

use DBI;
use DBD::Pg qw(:pg_types);

local $| = 1; # Don't batch output

package HTML::TreeBuilder;
use Modern::Perl;
use Carp;
# Monkeypatch in some extra methods, flows better this way

sub extract_one {
	my $tree = shift;
	my @matches = $tree->look_down(@_);
	if (@matches == 0) {
		carp "no matches for: " . join(", ", @_);
		return undef;
	} elsif (@matches > 1) {
		carp "too many matches for: " . join(", ", @_);
		return $matches[0];
	} else {
		# One match
		return $matches[0];
	}
}

sub extract_one_text {
	my $match = extract_one(@_);
	if ($match) {
		return $match->as_trimmed_text();
	} else {
		return ""; # Cause minimal errors, warning will flag investigation anyway
	}
}

package main;

sub parse_product_file {
	my $filename = shift;
	my $tree = HTML::TreeBuilder->new_from_file($filename);

	my $details; # hashref
	if ($tree->look_down("_tag", "div", "class", "product-details__productnumber")) {
		# First form of product page
		$details = parse_product_type1($filename, $tree);
	} elsif ($tree->look_down("class", "page-title")) {
		# Second form of product page
		$details = parse_product_type2($filename, $tree);
	} else {
		# Unknown - not a product page?
		croak "not a product page";
	}

	my $more_details = parse_product_datalayer($filename, $tree);

	return { %$details, %$more_details };
}

sub parse_product_datalayer {
	my ($filename, $tree) = @_;

	# Want to search through the Javasript for dataLayer.push() calls
	my @matches = $tree->look_down("_tag", "script");
	my %data;

	foreach (@matches) {
		my $content = join("", $_->content_list);
		# Some assumptions about special characters in the regex
		my @pushes = $content =~ /dataLayer\.push \s* \( \s* \{ ([^}]*)/xg;

		foreach (@pushes) {
			# Making assumptions about special characters like commas doesn't work
			# A single line regex is beyond me, can have surrounds of '', "" or none
			# So instead we do this substitution uglyness to allow the splits
			my @subs;
			my $sub_count = 0;
			s/(["']) (.*?) \1/$subs[$sub_count] = $2, "SUB".$sub_count++/xeg;

			# Making a bunch more special character assumptions :(
			# But the regex was getting hairy and couldn't handle both quote styles and no-quotes
			my @key_value = split(/,/);
			foreach (@key_value) {
				my ($k, $v) = split(/:/);
				if (defined($k) && defined($v)) {
					if ($k =~ /^\s*SUB(\d+)\s*$/) {
						$k = $subs[$1];
					} else {
						$k =~ s/^\s+//; $k =~ s/\s+$//; $k =~ s/^(["']) (.*) \1$/$2/x;
					}
					if ($v =~ /^\s*SUB(\d+)\s*$/) {
						$v = $subs[$1];
					} else {
						$v =~ s/^\s+//; $v =~ s/\s+$//; $v =~ s/^(["']) (.*) \1$/$2/x;
					}
					$data{$k} = $v;
				} else {
					carp "bad key-value extraction in $filename: ". $content;
				}
			}
		}
	}

	my %details = (
		product_number => $data{productid},
		price => $data{price},
		brand => $data{brand},
		category => [map {$data{$_}} sort grep {/^dim_\d+_catl\d+$/} keys %data],
	);

	return \%details;
}

sub parse_product_type1 {
	my ($filename, $tree) = @_;

	# Pull out all the bits we care about, stash them in %details
	my %details;

	$details{"title"} = $tree->extract_one_text("itemprop", "name");
	($details{"price"}) = $tree->extract_one_text("itemprop", "price") =~ /([\d,]+)/;
	($details{"download_time"}) = $tree->extract_one_text("class", "product-list__footnote") =~ /Price correct as at (.*)/;
	($details{"product_number"}) = $tree->extract_one_text("class", "product-details__productnumber") =~ /I\/N: \s* (\d*)/x;

	$details{"image"} = do {
		local $_ = $tree->extract_one("itemprop", "image");
		defined ? $_->attr('src') : undef;
	};

	# Breadcrumbs give the category, we pull it out elsewhere
	#my $bc = $tree->extract_one("class", "breadcrumb");

	# Optional description consists of some paragraphs and some dot points
	my $description = eval {
		local $SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /^no matches/ };
		return $tree->extract_one("id", "tab-description")
	};
	if ($description) {
		$details{"description_text"} = $description->look_down("itemprop", "description")->as_trimmed_text();
		$details{"description_bullets"} = [map {$_->as_trimmed_text()} $description->look_down("_tag", "li")];
	} else {
		$details{"description_text"} = undef;
		$details{"description_bullets"} = [];
	}

	# The specifications are a table that isn't, because tables aren't cool.
	# The result is worse than either.
	# We simplify this and extract the keys and values by tag styling, then stitch them together
	# We also have to work around broken HTML causing bad parsing, <dl> shouldn't contain <div>,
	# so the parser ignores the inside <div> and associates the </div> with the parent
	# Avoid this by not extracting the parent </div> Many specs, many broken divs.
	my @spec_keys = map {$_->as_trimmed_text()} $tree->look_down("_tag", "dt");
	my @spec_vals = map {$_->as_trimmed_text()} $tree->look_down("_tag", "dd");
	my %spec;
	@spec{@spec_keys} = @spec_vals;
	$details{specifications} = \%spec;

	return \%details;
}

sub parse_product_type2 {
	my ($filename, $tree) = @_;

	# Pull out all the bits we care about, stash them in %details
	my %details;

	$details{"title"} = $tree->extract_one_text("class", "page-title");
	($details{"price"}) = $tree->extract_one_text("itemprop", "price") =~ /([\d,.]+)/;
	($details{"download_time"}) = $tree->extract_one_text("class", "price-check-date") =~ /Price correct as at (.*)/;
	($details{"product_number"}) = $tree->extract_one_text("class", "product-in") =~ /I\/N: \s* (\d*)/x;

	# Image slider thing, hopefully there is only ever one
	# TODO: Can have multiple images, see ozito-130w-electric-air-pump_p6290537 (x175)
	$details{"image"} = do {
		local $_ = $tree->extract_one("class", "rsImg");
		defined ? $_->attr('src') : undef;
	};

	# Description consists of some paragraphs and some dot points
	my $description = $tree->extract_one("id", "tab-description");
	if (defined($description)) {
		$details{"description_text"} = $description->look_down("itemprop", "description")->as_trimmed_text();
		$details{"description_bullets"} = [map {$_->as_trimmed_text()} $description->look_down("_tag", "li")];
	} else {
		($details{"description_text"}, $details{"description_bullets"}) = (undef, []);
	}

	# The specifications are a table that isn't, because tables aren't cool.
	# The result is worse than either.
	# We simplify this and extract the keys and values by tag styling, then stitch them together
	# We also have to work around broken HTML causing bad parsing, <dl> shouldn't contain <div>,
	# so the parser ignores the inside <div> and associates the </div> with the parent
	# Avoid this by not extracting the parent </div> Many specs, many broken divs.
	my @spec_keys = map {$_->as_trimmed_text()} $tree->look_down("_tag", "dt");
	my @spec_vals = map {$_->as_trimmed_text()} $tree->look_down("_tag", "dd");
	my %spec;
	@spec{@spec_keys} = @spec_vals;
	$details{specifications} = \%spec;

	return \%details;
}


sub prep_postgres_array {
	my @arr = ref $_[0] eq "ARRAY" ? @{$_[0]} : @_;
	return '{' . join(",", map {s/\\/\\\\/; s/"/\\"/g; '"'.$_.'"'} @arr) . '}';
}

sub insert_product {
	my $product = shift;

	state $dbh = DBI->connect("dbi:Pg:dbname=bunnings", "", "", {RaiseError => 1, PrintError => 0,
		ShowErrorStatement => 1});
	#$dbh->{TraceLevel} = "SQL";

	state $prod_sth = do {
		my $sql = "INSERT INTO product (product_number, download_time, image, price, title, description_text, brand, description_bullets, category) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
		$dbh->prepare($sql);
	} or die $dbh->errstr;

	state $spec_sth = do {
		my $sql = "INSERT INTO specification (product_number, key, value) VALUES (?, ?, ?)";
		$dbh->prepare($sql);
	} or die $dbh->errstr;

	$prod_sth->execute(map( {$product->{$_}} qw/product_number download_time image price title description_text brand/), prep_postgres_array($product->{"description_bullets"}), prep_postgres_array($product->{"category"}));

	foreach (keys %{$product->{specifications}}) {
		$spec_sth->execute($product->{"product_number"}, $_, $product->{specifications}{$_});
	}
}

sub parse_single_file {
	my ($path) = @_;

	unless (-f $path and $path =~ /.*-.*_p\d+/) {
		say "Skipped $path";
		return;
	}

	try {
		#dd(parse_product_file($path));
		insert_product(parse_product_file($path));
		say "Parsed $path";
	} catch {
		chomp; # Errors often end in newline
		say "Parsing $path failed : ", $_;
	};
}

my $directory = shift(@ARGV) || '.';

if (-f $directory) {
	# Can specify a single file
	say "Parsing single file $directory";
	parse_single_file($directory);
	exit();
}

# We parse files in the directory, we do NOT search recursively
say "Parsing files in $directory";

opendir (my $dir, $directory) or die $!;
while (my $file  = readdir($dir)) {
	parse_single_file("$directory/$file");
}
