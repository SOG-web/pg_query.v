.PHONY: all build test clean dev-setup

all: build

build:
	make -C libpg_query build
	cp libpg_query/libpg_query.a c/libpg_query.a

dev-setup:
	ln -sf . pg_query

test: build
	v test .

clean:
	make -C libpg_query clean
	rm -rf c/libpg_query.a
