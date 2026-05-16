.PHONY: all build test clean

all: build

build: pg_query/c_bridge.o libpg_query/libpg_query.a

pg_query/c_bridge.o: pg_query/c_bridge.c pg_query/c_bridge.h libpg_query/pg_query.h
	cc -c -I libpg_query pg_query/c_bridge.c -o pg_query/c_bridge.o

libpg_query/libpg_query.a:
	make -C libpg_query build

test: build
	v test pg_query/

clean:
	rm -f pg_query/c_bridge.o
	make -C libpg_query clean
