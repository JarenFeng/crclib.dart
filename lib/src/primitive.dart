// Copyright 2020 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert' show ByteConversionSinkBase;

/// Represents a CRC value. Objects of this class should only be tested for
/// equality against [int] or [BigInt], and printed with [toString] or
/// [toRadixString].
class CrcValue {
  final dynamic _value;
  final int _width;

  // BigInt values are ensured to be non-negative. But int values can go
  // negative due to the shifts and xors affecting the most-significant bit.
  CrcValue(this._width, this._value)
      : assert(_value is int || (_value is BigInt && !_value.isNegative));

  @override
  int get hashCode => _value.hashCode;

  @override
  bool operator ==(Object other) {
    if (other is CrcValue && _width == other._width) {
      return this == other._value;
    } else if (other is int) {
      if (_value is int) {
        return _value == other;
      }
      return BigInt.from(other).toUnsigned(_width) == _value;
    } else if (other is BigInt && !other.isNegative) {
      if (_value is BigInt) {
        return _value == other;
      }
      return BigInt.from(_value as int).toUnsigned(_width) == other;
    }
    return false;
  }

  @override
  String toString() {
    return toRadixString(10);
  }

  String toRadixString(int radix) {
    if (_value is int) {
      return (_value as int).toRadixString(radix);
    }
    return (_value as BigInt).toRadixString(radix);
  }
}

/// Ultimate sink that stores the final CRC value.
class FinalSink extends Sink<CrcValue> {
  CrcValue _value;

  CrcValue get value {
    assert(_value != null);
    return _value;
  }

  @override
  void add(CrcValue data) {
    // Can only be called once.
    assert(_value == null);
    _value = data;
  }

  @override
  void close() {
    assert(_value != null);
  }
}

/// Intermediate sink that performs the actual CRC calculation. It outputs to
/// [FinalSink].
abstract class _CrcSink<T> extends ByteConversionSinkBase {
  final List<T> table;
  final T finalMask;
  final Sink<CrcValue> _outputSink;
  CrcLoopFunction _loopFunction;
  T value;
  int width;
  bool _closed;

  _CrcSink(this.table, this.value, this.finalMask, this._outputSink, this.width)
      : _closed = false,
        assert(value is int || value is BigInt) {
    _loopFunction = selectLoopFunction();
  }

  @override
  void add(List<int> chunk) {
    addSlice(chunk, 0, chunk.length, false /* isLast */);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    _loopFunction(chunk, start, end);
    if (isLast) {
      close();
    }
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      if (value is int) {
        var v = (value as int) ^ (finalMask as int);
        _outputSink.add(CrcValue(width, v));
      } else {
        var v = (value as BigInt) ^ (finalMask as BigInt);
        _outputSink.add(CrcValue(width, v));
      }
      _outputSink.close();
    }
  }

  CrcLoopFunction selectLoopFunction();
}

typedef CrcLoopFunction = void Function(List<int> chunk, int start, int end);

/// "Normal" CRC routines where the high bits are shifted out to the left.
///
/// The various [CrcLoopFunction] definitions are to optimize for different
/// integer sizes in Dart VM. See "Optimally shifting to the left" in
/// https://www.dartlang.org/articles/dart-vm/numeric-computation.
///
// Note for maintainers: Try not to call any function in these loops. Function
// calls require boxing and unboxing.
abstract class NormalSink<T> extends _CrcSink<T> {
  NormalSink(
      List<T> table, T value, T finalMask, Sink<CrcValue> outputSink, int width)
      : super(table, value, finalMask, outputSink, width);
}

/// A normal sink backed by BigInt values.
class NormalSinkBigInt extends NormalSink<BigInt> {
  NormalSinkBigInt(List<BigInt> table, BigInt value, BigInt finalMask,
      Sink<CrcValue> outputSink, int width)
      : super(table, value, finalMask, outputSink, width);

  void _crcLoop(List<int> chunk, int start, int end) {
    final shiftWidth = width - 8;
    final mask = (BigInt.one << shiftWidth) - BigInt.one;
    for (final b in chunk.getRange(start, end)) {
      value = table[((value >> shiftWidth).toUnsigned(8).toInt() ^ b) & 0xFF] ^
          ((value & mask) << 8);
    }
  }

  @override
  CrcLoopFunction selectLoopFunction() {
    return _crcLoop;
  }
}

/// Reflects the least [width] bits of input value [i].
///
/// For example: the value of `_reflect(0x80, 8)` is 0x01 because 0x80 is
/// 10000000 in binary; its reflected binary value is 00000001, which is 0x01 in
/// hexadecimal. And `_reflect(0x3e23, 3)` is 6 because the least significant 3
/// bits are 011, when reflected is 110, which is 6 in decimal.
int reflectInt(int i, int width) {
  var ret = 0;
  while (width-- > 0) {
    ret = (ret << 1) | (i & 1);
    i >>= 1;
  }
  return ret;
}

BigInt reflectBigInt(BigInt i, int width) {
  var ret = BigInt.zero;
  while (width-- > 0) {
    ret = (ret << 1) | (i.isOdd ? BigInt.one : BigInt.zero);
    i >>= 1;
  }
  return ret;
}

/// "Reflected" CRC routines.
///
/// The specialized loop functions are meant to speed up calculations
/// according to the width of the CRC value.
abstract class ReflectedSink<T> extends _CrcSink<T> {
  ReflectedSink(List<T> table, T reflectedValue, T finalMask,
      Sink<CrcValue> outputSink, int width)
      : super(table, reflectedValue, finalMask, outputSink, width);
}

class ReflectedSinkBigInt extends ReflectedSink<BigInt> {
  ReflectedSinkBigInt(List<BigInt> table, BigInt value, BigInt finalMask,
      Sink<CrcValue> outputSink, int width)
      : super(table, reflectBigInt(value, width), finalMask, outputSink, width);

  void _crcLoop(List<int> chunk, int start, int end) {
    for (final b in chunk.getRange(start, end)) {
      value = table[(value.toUnsigned(8).toInt() ^ b) & 0xFF] ^ (value >> 8);
    }
  }

  @override
  CrcLoopFunction selectLoopFunction() {
    return _crcLoop;
  }
}