# bunnings-siterip

This code is designed to pull product information from https://www.bunnings.com.au/

`wget` is used to build an offline mirror of the bunnings website.
The `parse_product.pl` script then harvests all the information from each product page, storing it in a database.

This code was written as a one off script and provided in the hope that it may be useful. It worked for me, once, the code is not of particularly high quality and fancy extras like unit tests were not created, there is however extensive logging. If using it you should expect to have to do some debugging, in particular any changes to the bunnings website will need to be accounted for.


# offline mirror

I used wget to generate an offline mirror to work with. Each product page is 300k, despite eliminating images and downloads the full mirror comes to roughly 22G.

```
$ wget --append-output=fetch.log --no-clobber --keep-session-cookies --save-cookies cookies --recursive --timestamping --level=inf --no-remove-listing --reject jpg,jpeg,png,gif,pdf,doc,docx https://www.bunnings.com.au/
```

# prepare database

A postgresql database used to store the information, a guide is provided later to convert the tables to mysql if desired.

I run my development machines with postgresql trusting local connections, if you require passwords for access you will need to supply them here and to the script.

```
$ createdb bunnings
$ psql bunnings < db.sql
```

# harvest the information

The perl script will work through the product files in the supplied directory, pushing the data into the database.

It will take a while, I suggest running overnight.

```
$ perl parse_product.pl mirror/www.bunnings.com.au/ > product.20170212.log
```

You should examine the log for any errors, the following greps may be useful.
Note that some (626) duplicate key errors is normal, there are duplicated product pages.
There are also a couple (17) of pages which don't contain any product information.

```
$ grep -v "Parsed" product.20170212.log
$ grep -v -e "Parsed" -e "duplicate key value violates" -e "already exists" -e "Skipped" -e "not a product page" product.20170212.log
```

# mysql/mariadb conversion

The scripts are designed to populate a postgresql database.

The tables can be extracted and used to populate a mysql database using the following:

```
psql=# COPY (SELECT product_number, title, brand, price, image, download_time, array_to_json(category) AS category, description_text, array_to_json(description_bullets) AS description_bullets from product) TO '/tmp/product_dump.tsv';

psql=# COPY (SELECT product_number, key, value FROM specification) TO '/tmp/specification_dump.tsv';
```

```
mysql> CREATE TABLE product (
    product_number INTEGER PRIMARY KEY,
    title TEXT,
    brand TEXT,
    price TEXT,
    image TEXT,
    download_time DATETIME,
    # mysql 5.7 introduces a native JSON type which could be used for the JSON arrays
    category TEXT, # JSON array
    description_text TEXT,
    description_bullets TEXT # JSON array
);

mysql> CREATE TABLE specification (
    product_number INTEGER REFERENCES product(product_number),
    # key is a reserved word :( specification is less fiddly than escaping
    # VARCHAR allows indexing
    # using utf8_bin forces the index to be case sensitive
    specification VARCHAR(80) CHARACTER SET utf8 COLLATE utf8_bin,
    value TEXT,
    PRIMARY KEY (product_number, specification)
);

mysql> LOAD DATA INFILE '/tmp/product_dump.tsv' INTO TABLE product;
mysql> LOAD DATA INFILE '/tmp/specification_dump.tsv' INTO TABLE specification;
```


# other scripts

Two other scripts were created during development and are provided but should not be necessary.

`parse_range.pl` parses the category pages, which bunnings calls its range. This was not useful to me, all the data I needed could be found on the product page, it may be useful for you.

`check_fail.pl` examines a log file and double checks that each referenced page exists in the database, it was useful to catch faulty parses during development.


# a note on copyright

Copyright issues are always a concern with this type of work, just because you can do it doesn't mean you are allowed to do it. My understanding is that acquiring the data is typically ok however republishing it may cause issues, the `description_text` field is a particular concern. You should seek your own legal advice relevant to your country.

