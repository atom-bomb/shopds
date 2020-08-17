# shopds

here is a shell script to generate an OPDS Catalog from a directory of e-books.

shopds has been tested to work on linux in bash, dash and ash.
it is intended for use on OpenWRT/LEDE servers to provide a lightweight
alternative to running a Calibre server.

```
shopds.sh usage:
-h             : print this help and exit
-v             : verbose output
-o [directory] : specify an alternate output directory
-r [filename]  : specify an alternate root filename
-t [title]     : specify an alternate catalog title
-a [author]    : specify an alternate catalog author
-d [directory] : specify an alternate directory to scan
```
