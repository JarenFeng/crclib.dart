Dart crclib
===========

*This is not an official Google product.*

Generic CRC calculations as Dart converters and some common algorithms.

The easiest way to use this library is to call `convert` on the instance of
the desired CRC routine.

```
  Crc32Xz().convert(utf8.encode('123456789')) == 0xCBF43926
```

Another supported use case is as stream transformers.

```
  File(...).openRead().transform(Crc32Xz()).single.then(...)
```

Instead of using predefined classes, it is also possible to construct a
customized CRC function with `ParametricCrc` class. For a list of known
CRC routines, check out https://reveng.sourceforge.io/crc-catalogue/all.htm.

TODO:

  1. `inputReflected` and `outputReflected` can be different, see CRC-12/UMTS.
  2. Bit-level checksums (including non-multiple-of-8 checksums).
