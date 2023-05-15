# i18n experiment

An experiment at creating an translation library for use with Zig.

One goal is that starting to use this should be as easy as
replacing all instances like `writer.print("...", .{...})`
with `i18n.print(writer, "...", .{...})`
where the format string becomes the key for translation.

Translations are specified in `$LOCALE.def` files so for code like
```zig
i18n.print(writer, "Hello {s}!", .{name});
```
A finnish translation file `fi_FI.def` would contain something like:
```
# Comment explaining something about this translation
def "Hello {%1}!"
"Moikka {%1}!"
```