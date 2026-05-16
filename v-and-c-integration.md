# V and C

The basic mapping between C and V types is described in [C and V Type Interoperability](https://github.com/vlang/v/blob/master/doc/c_and_v_type_interoperability.md).

## Calling C from V

V currently does not have a parser for C code. That means that even though it allows you to `#include` existing C header and source files, it will not know anything about the declarations in them. The `#include` statement will only appear in the generated C code, to be used by the C compiler backend itself.

**Example of #include**

```v
#include <stdio.h>
```

After this statement, V will *not* know anything about the functions and structs declared in `stdio.h`, but if you try to compile the .v file, it will add the include in the generated C code, so that if that header file is missing, you will get a C error (you will not in this specific case, if you have a proper C compiler setup, since `<stdio.h>` is part of the standard C library).

To overcome that limitation (that V does not have a C parser), V needs you to redeclare the C functions and structs, on the V side, in your `.c.v` files. Note that such redeclarations only need to have enough details about the functions/structs that you want to use. Note also that they *do not have* to be complete, unlike the ones in the .h files.

**C struct redeclarations** For example, if a struct has 3 fields on the C side, but you want to only refer to 1 of them, you can declare it like this:

```v
struct C.NameOfTheStruct { a_field int }
```

Another feature, that is very frequently needed for C interoperability, is the `@[typedef]` attribute. It is used for marking `C.` structs, that are defined with `typedef struct SomeName { ..... } TypeName;` in the C headers.

For that case, you will have to write something like this in your .c.v file:

```v
@[typedef] pub struct C.TypeName { }
```

Note that the name of the `C.` struct in V, is the one *after* the `struct SomeName {...}`.

**C function redeclarations** The situation is similar for `C.` functions. If you are going to call just 1 function in a library, but its .h header declares dozens of them, you will only need to declare that single function, for example:

```v
fn C.name_of_the_C_function(param1 int, const_param2 &char, param3 f32) f64
```

... and then later, you will be able to call the same way you would V function:

```v
f := C.name_of_the_C_function(123, c'here is some C style string', 1.23)
dump(f)
```

**Example of using a C function from stdio, by redeclaring it on the V side**

```v
#include <stdio.h> // int dprintf(int fd, const char *format, ...)

fn C.dprintf(fd int, const_format &char, ...voidptr) int

value := 12345
x := C.dprintf(0, c'Hello world, value: %d\n', value)
dump(x)
```

If your C backend compiler is properly setup, you should see something like this, when you try to run it:

```console
#0 10:42:32 /v/examples> v run a.v
Hello world, value: 12345
[a.v:8] x: 26
#0 10:42:33 /v/examples>
```

Note, that the C function redeclarations look very similar to the V ones, with some differences:

1. They lack a body (they are defined on the C side).
2. Their names start with `C.`.
3. Their names can have capital letters (unlike V ones, that are required to use snake_case).

Note also the second parameter `const char *format`, which was redeclared as `const_format &char`. The `const_` prefix in that redeclaration may seem arbitrary, but it is important, if you want to compile your code with `-cstrict` or thirdparty C static analysis tools. V currently does not have another way to express that this parameter is a const (this will probably change in V 1.0).

For some C functions, that use variadics (`...`) as parameters, V supports a special syntax for the parameters - `...voidptr`, that is not available for ordinary V functions (V's variadics are *required* to have the same exact type). Usually those are functions of the printf/scanf family i.e for `printf`, `fprintf`, `scanf`, `sscanf`, etc, and other formatting/parsing/logging functions.

**Example: SQLite integration**

```v
#flag freebsd -I/usr/local/include -L/usr/local/lib
#flag -lsqlite3
#include "sqlite3.h"
// See also the example from https://www.sqlite.org/quickstart.html
pub struct C.sqlite3 {
}
pub struct C.sqlite3_stmt {
}
type FnSqlite3Callback = fn (voidptr, int, &&char, &&char) int

fn C.sqlite3_open(&char, &&C.sqlite3) int
fn C.sqlite3_close(&C.sqlite3) int
fn C.sqlite3_column_int(stmt &C.sqlite3_stmt, n int) int
// ... you can also just define the type of parameter and leave out the C. prefix
fn C.sqlite3_prepare_v2(&C.sqlite3, &char, int, &&C.sqlite3_stmt, &&char) int
fn C.sqlite3_step(&C.sqlite3_stmt)
fn C.sqlite3_finalize(&C.sqlite3_stmt)
fn C.sqlite3_exec(db &C.sqlite3, sql &char, cb FnSqlite3Callback, cb_arg voidptr, emsg &&char) int
fn C.sqlite3_free(voidptr)

fn my_callback(arg voidptr, howmany int, cvalues &&char, cnames &&char) int {
    unsafe {
        for i in 0 .. howmany {
            print('| ${cstring_to_vstring(cnames[i])}: ${cstring_to_vstring(cvalues[i]):20} ')
        }
    }
    println('|')
    return 0
}

fn main() {
    db := &C.sqlite3(unsafe { nil }) // this means `sqlite3* db = 0`
    // passing a string literal to a C function call results in a C string, not a V string
    C.sqlite3_open(c'users.db', &db)
    // C.sqlite3_open(db_path.str, &db)

    query := 'select count(*) from users'
    stmt := &C.sqlite3_stmt(unsafe { nil })

    // Note: You can also use the `.str` field of a V string,
    // to get its C style zero terminated representation
    C.sqlite3_prepare_v2(db, &char(query.str), -1, &stmt, 0)
    C.sqlite3_step(stmt)
    nr_users := C.sqlite3_column_int(stmt, 0)
    C.sqlite3_finalize(stmt)
    println('There are ${nr_users} users in the database.')

    error_msg := &char(unsafe { nil })
    query_all_users := 'select * from users'
    rc := C.sqlite3_exec(db, &char(query_all_users.str), my_callback, voidptr(7), &error_msg)
    if rc != C.SQLITE_OK {
        eprintln(unsafe { cstring_to_vstring(error_msg) })
        C.sqlite3_free(error_msg)
    }
    C.sqlite3_close(db)
}
```

## Calling V from C

Since V can compile to C, calling V code from C is very easy, once you know how.

Use `v -o file.c your_file.v` to generate a C file, corresponding to the V code.

More details in [call_v_from_c example](https://github.com/vlang/v/blob/master/doc/../examples/call_v_from_c).

## Passing C compilation flags

Add `#flag` directives to the top of your V files to provide C compilation flags like:

- `-I` for adding C include files search paths
- `-l` for adding C library names that you want to get linked
- `-L` for adding C library files search paths
- `-D` for setting compile time variables

You can also use `#flag` directives, to link to static C libraries, which will be added last (note the .a suffix):

```v
#flag /path/to/ffi.a
```

If you need to reverse the order (prepend the static library in the libs section of the C compilation line, before other libs), use:

```v
#flag /path/to/ffi.a@START_LIBS
```

You can (optionally) use different flags for different targets. Every OS listed in [Compile time code](conditional-compilation.html#compile-time-code) is supported as flags.

> **NOTE:** Each flag must go on its own line (for now)

```v
#flag linux -lsdl2
#flag linux -Ivig
#flag linux -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS=1
#flag linux -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1
#flag linux -DIMGUI_IMPL_API=
```

In the console build command, you can use:

- `-cc` to change the default C backend compiler.
- `-cflags` to pass custom flags to the backend C compiler (passed before other C options).
- `-ldflags` to pass custom flags to the backend C linker (passed after every other C option).
- For example: `-cc gcc-9 -cflags -fsanitize=thread`.

You can define a `VFLAGS` environment variable in your terminal to store your `-cc` and `-cflags` settings, rather than including them in the build command each time.

## #pkgconfig

Add `#pkgconfig` directives to tell the compiler which modules should be used for compiling and linking using the pkg-config files provided by the respective dependencies.

As long as backticks can't be used in `#flag` and spawning processes is not desirable for security and portability reasons, V uses its own pkgconfig library that is compatible with the standard freedesktop one.

If no flags are passed it will add `--cflags` and `--libs` to pkgconfig (not to V). In other words, both lines below do the same:

```v
#pkgconfig r_core
#pkgconfig --cflags --libs r_core
```

The `.pc` files are looked up into a hardcoded list of default pkg-config paths, the user can add extra paths by using the `PKG_CONFIG_PATH` environment variable. Multiple modules can be passed.

To check the existence of a pkg-config use `$pkgconfig('pkg')` as a compile time "if" condition to check if a pkg-config exists. If it exists the branch will be created. Use `$else` or `$else $if` to handle other cases.

```v
$if $pkgconfig('mysqlclient') {
    #pkgconfig mysqlclient
} $else $if $pkgconfig('mariadb') {
    #pkgconfig mariadb
}
```

## Including C code

You can also include C code directly in your V module. For example, let's say that your C code is located in a folder named 'c' inside your module folder. Then:

1. Put a v.mod file inside the toplevel folder of your module (if you created your module with `v new` you already have v.mod file). For example:

```
Module {
    name: 'mymodule',
    description: 'My nice module wraps a simple C library.',
    version: '0.0.1'
    dependencies: []
}
```

2. Add these lines to the top of your module:

```v
#flag -I @VMODROOT/c
#flag @VMODROOT/c/implementation.o
#include "header.h"
```

> **NOTE:** `@VMODROOT` will be replaced by V with the *nearest parent folder, where there is a v.mod file*. Any .v file beside or below the folder where the v.mod file is, can use `#flag @VMODROOT/abc` to refer to this folder. The `@VMODROOT` folder is also *prepended* to the module lookup path, so you can *import* other modules under your `@VMODROOT`, by just naming them.

The instructions above will make V look for an compiled .o file in your module `folder/c/implementation.o`. If V finds it, the .o file will get linked to the main executable, that used the module. If it does not find it, V assumes that there is a `@VMODROOT/c/implementation.c` file, and tries to compile it to a .o file, then will use that.

This allows you to have C code, that is contained in a V module, so that its distribution is easier. You can see a complete minimal example for using C code in a V wrapper module here: [project_with_c_code](https://github.com/vlang/v/tree/master/vlib/v/tests/project_with_c_code). Another example, demonstrating passing structs from C to V and back again: [interoperate between C to V to C](https://github.com/vlang/v/tree/master/vlib/v/tests/project_with_c_code_2).

## C types

Ordinary zero terminated C strings can be converted to V strings with `unsafe { &char(cstring).vstring() }` or if you know their length already with `unsafe { &char(cstring).vstring_with_len(len) }`.

> **NOTE:** The `.vstring()` and `.vstring_with_len()` methods do NOT create a copy of the `cstring`, so you should NOT free it after calling the method `.vstring()`. If you need to make a copy of the C string (some libc APIs like `getenv` pretty much require that, since they return pointers to internal libc memory), you can use `cstring_to_vstring(cstring)`.

On Windows, C APIs often return so called `wide` strings (UTF-16 encoding). These can be converted to V strings with `string_from_wide(&u16(cwidestring))`.

V has these types for easier interoperability with C:

- `voidptr` for C's `void*`
- `&u8` for C's `byte*`
- `&char` for C's `char*`
- `&&char` for C's `char**`

To cast a `voidptr` to a V reference, use `user := &User(user_void_ptr)`.

`voidptr` can also be dereferenced into a V struct through casting: `user := User(user_void_ptr)`.

[An example of a module that calls C code from V](https://github.com/vlang/v/blob/master/vlib/v/tests/project_with_c_code/mod1/wrapper.c.v)

## C Declarations

C identifiers are accessed with the `C` prefix similarly to how module-specific identifiers are accessed. Functions must be redeclared in V before they can be used. Any C types may be used behind the `C` prefix, but types must be redeclared in V in order to access type members.

To redeclare complex types, such as in the following C code:

```c
struct SomeCStruct {
    uint8_t implTraits;
    uint16_t memPoolData;
    union {
        struct {
            void* data;
            size_t size;
        };
        DataView view;
    };
};
```

Members of sub-data-structures may be directly declared in the containing struct as below:

```v
pub struct C.SomeCStruct {
    implTraits u8
    memPoolData u16
    // These members are part of sub data structures that can't currently be represented in V.
    // Declaring them directly like this is sufficient for access.
    // union {
    // struct {
    data voidptr
    size usize
    // }
    // view C.DataView
    // }
}
```

The existence of the data members is made known to V, and they may be used without re-creating the original structure exactly.

Alternatively, you may [embed](structs.html#embedded-structs) the sub-data-structures to maintain a parallel code structure.

## Export to shared library

By default all V functions have the following naming scheme in C: `[module name]__[fn_name]`.

For example, `fn foo() {}` in module `bar` will result in `bar__foo()`.

To use a custom export name, use the `@[export]` attribute:

```v
@[export: 'my_custom_c_name']
fn foo() {
}
```

## Translating C to V

V can translate your C code to human readable V code, and generating V wrappers on top of C libraries.

C2V currently uses Clang's AST to generate V, so to translate a C file to V you need to have Clang installed on your machine.

Let's create a simple program `test.c` first:

```c
#include "stdio.h"
int main() {
    for (int i = 0; i < 10; i++) {
        printf("hello world\n");
    }
    return 0;
}
```

Run `v translate test.c`, and V will generate `test.v`:

```v
fn main() {
    for i := 0; i < 10; i++ {
        println('hello world')
    }
}
```

To generate a wrapper on top of a C library use this command:

```bash
v translate wrapper c_code/libsodium/src/libsodium
```

This will generate a directory `libsodium` with a V module.

Example of a C2V generated libsodium wrapper: [https://github.com/vlang/libsodium](https://github.com/vlang/libsodium)

**When should you translate C code and when should you simply call C code from V?**

If you have well-written, well-tested C code, then of course you can always simply call this C code from V.

Translating it to V gives you several advantages:

- If you plan to develop that code base, you now have everything in one language, which is much safer and easier to develop in than C.
- Cross-compilation becomes a lot easier. You don't have to worry about it at all.
- No more build flags and include files either.

## Working around C issues

In some cases, C interop can be extremely difficult. One of these such cases is when headers conflict with each other. For example, V needs to include the Windows header libraries in order for your V binaries to work seamlessly across all platforms.

However, since the Windows header libraries use extremely generic names such as `Rectangle`, this will cause a conflict if you wish to use C code that also has a name defined as `Rectangle`.

For very specific cases like this, V has `#preinclude` and `#postinclude` directives.

These directives allow things to be configured *before* V adds in its built in libraries, and *after* all of the V code generation has completed (and thus all of the prototypes, declarations and definitions are already present).

Example usage:

```v
// This will include before built in libraries are used.
#preinclude "pre_include.h"
// This will include after built in libraries are used.
#include "include.h"
// This will include after all of the V code generation is complete,
// including the one for the main function of the project
#postinclude "post_include.h"
```

An example of what might be included in `pre_include.h` can be [found here](https://github.com/irishgreencitrus/raylib.v/blob/main/include/pre.h).

The `#postinclude` directive on the other hand is useful for allowing the integration of frameworks like SDL3 or Sokol, that insist on having callbacks in your code, instead of behaving like ordinary libraries, and allowing you to decide when to call them.

> **NOTE:** These are advanced features, and will not be necessary outside of very specific cases with C interop. Other than those, using them could cause more issues than it solves. Consider using them as a last resort!
