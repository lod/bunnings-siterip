DROP TABLE IF EXISTS product_category;
DROP TABLE IF EXISTS category_item;
DROP TABLE IF EXISTS category;
DROP TABLE IF EXISTS specification;
DROP TABLE IF EXISTS product;

CREATE TABLE product (
	download_time TIMESTAMP WITH TIME ZONE,
	image TEXT,
	price MONEY,
	title TEXT,
	product_number INTEGER PRIMARY KEY,
	description_bullets TEXT[],
	description_text TEXT,
	brand TEXT,
	category TEXT[]
);

CREATE TABLE specification (
	product_number INTEGER REFERENCES product(product_number),
	key TEXT,
	value TEXT,
	PRIMARY KEY (product_number, key)
);

CREATE TABLE category (
	id SERIAL PRIMARY KEY, /* TODO: artificial key, maybe use concatonated breadcrumbs instead? */
	breadcrumbs TEXT[]
);


CREATE TABLE category_item (
	id SERIAL PRIMARY KEY, /* TODO: artificial key, is product_id safe? maybe product_id, category_page */
	name TEXT,
	product_id INTEGER,
	category_page INTEGER REFERENCES category(id),
	category TEXT, /* Data category field, sometimes null, sometimes related but not the same as the page category breadcrumbs */
	url TEXT,
	image TEXT,
	brand_image TEXT,
	brand TEXT,
	price MONEY
);

CREATE TABLE product_category (
	product INTEGER REFERENCES product(product_number),
	category INTEGER REFERENCES category(id),
	PRIMARY KEY (product, category)
);
