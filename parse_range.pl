#!/usr/bin/perl

use Modern::Perl;
use autodie;
use Try::Tiny;
use HTML::Tree;

use Carp;
use File::Find;
use Data::Dump;

use DBI;
use DBD::Pg qw(:pg_types);

local $| = 1; # Don't batch output

package HTML::Element;
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

sub extract_attr {
	my $tree = shift;
	my $attr_arg = pop;

	my @matches = $tree->look_down(@_);
	return @matches == 1 ? $matches[0]->attr($attr_arg) : undef;
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

sub parse_range_file {
	my $filename = shift;

	my $tree = HTML::TreeBuilder->new();
	$tree->warn(1);
	$tree->ignore_unknown(0);
	$tree->parse_file($filename);

	my @breadcrumbs = map {$_->as_trimmed_text()} $tree->look_down("class", "breadcrumb")->look_down("_tag", "span");

	my @entries;
	foreach ($tree->look_down("_tag", "article")) {
		my %e;
		$e{"name"}        = $_->attr("data-tracking-title");
		$e{"product_id"}  = $_->attr("data-tracking-identifier");
		$e{"category"}    = $_->attr("data-tracking-category");
		$e{"url"}         = $_->extract_attr("class", "product-list__link", "href");
		$e{"image"}       = $_->extract_attr("class", "photo lazy", "data-original");
		my $brand         = $_->look_down("class", "product-list__logo brand");
		# Brand is not always provided
		($e{"brand_image"}, $e{"brand"}) = $brand ? ($brand->attr("src"), $brand->attr("alt")) : ("", "");
		$e{"price"}       = [$_->extract_one("class", qr/product-list__price/)->as_text() =~ /([\d,]+)/]->[0];

		# There are some product bundles such as https://www.bunnings.com.au/backyard-fun_bbundle0129
		# These are a collection of multiple products, interesting but not relevent to my needs
		# Just skip rather than figure out how to handle them properly
		next if $e{"product_id"} =~ /bundle/;

		push @entries, \%e;
	}

	return { breadcrumbs => \@breadcrumbs, entries => \@entries };
}



sub prep_postgres_array {
	my @arr = ref $_[0] eq "ARRAY" ? @{$_[0]} : @_;
	return '{' . join(",", map {s/\\/\\\\/; s/"/\\"/g; '"'.$_.'"'} @arr) . '}';
}

my $dbh = DBI->connect("dbi:Pg:dbname=bunnings", "", "",
	{RaiseError => 1, PrintError => 0, ShowErrorStatement => 1});

sub insert_category {
	my $range = shift;

	state $cat_sth = do {
		my $cat_sql = "INSERT INTO category (breadcrumbs) VALUES (?) RETURNING id";
		$dbh->prepare($cat_sql);
	};

	state $cat_sel = do {
		my $sql = "SELECT id FROM category WHERE breadcrumbs = ?";
		$dbh->prepare($sql);
	};

	# Breadcrumbs sometimes start with "Our Range", sometimes "Home" then "Our Range"
	# Both are useless so just cull them out
	my @breadcrumbs = grep {!(/^Home$/ || /^Our Range$/)} @{$range->{"breadcrumbs"}};
	my $pg_breadcrumbs = prep_postgres_array(@breadcrumbs);

	# Categories are repeated, don't want to reinsert if it exists
	$cat_sel->execute($pg_breadcrumbs);
	my $r = $cat_sel->fetchrow_arrayref;

	if (defined $r) {
		# We returned an id
		return $r->[0];
	} else {
		# Row doesn't exist, create it
		$cat_sth->execute($pg_breadcrumbs);
		return $cat_sth->fetchrow_arrayref()->[0];
	}
}

sub insert_category_item {
	my ($cat_id, $range) = @_;

	state @item_fields;
	@item_fields = qw/name product_id category url image brand_image brand price/ unless @item_fields;

	state $item_sth = do {
		my $item_sql = "INSERT INTO category_item ".
			"(category_page, ".join(",", @item_fields).") ".
			"VALUES (?,".join(",", map {"?"} @item_fields).")";
		$dbh->prepare($item_sql);
	};

	$item_sth->execute($cat_id, @{$_}{@item_fields}) foreach (@{$range->{"entries"}});
}

sub insert_product_category {
	my ($cat_id, $range) = @_;

	state $sth = do {
		my $sql = "INSERT INTO product_category (category, product) VALUES (?, ?)";
		$dbh->prepare($sql);
	};

	$sth->execute($cat_id, $_->{"product_id"}) foreach (@{$range->{"entries"}});
}


my $directory = shift(@ARGV) || '.';
say "Recursively parsing files in $directory";

find( sub {
	return unless -f;

	my $file = $_;

    try {
        my $range = parse_range_file($file);
		dd($range);
        my $cat_id = insert_category($range);
		#insert_category_item($cat_id, $range);
		insert_product_category($cat_id, $range);
        say "Parsed $file";
    } catch {
        chomp; # Errors often end in newline
        say "Parsing $file failed : ", $_;
    };
}, $directory);
