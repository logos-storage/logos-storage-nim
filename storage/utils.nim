## Logos Storage
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

{.push raises: [].}

import std/parseutils
import std/options

import pkg/chronos

import ./utils/asyncheapqueue
import ./utils/fileutils
import ./utils/asynciter
import ./utils/safeasynciter

export asyncheapqueue, fileutils, asynciter, safeasynciter, chronos

when defined(posix):
  import os, posix

func divUp*[T: SomeInteger](a, b: T): T =
  ## Division with result rounded up (rather than truncated as in 'div')
  assert(b != T(0))
  if a == T(0):
    T(0)
  else:
    ((a - T(1)) div b) + T(1)

func roundUp*[T](a, b: T): T =
  ## Round up 'a' to the next value divisible by 'b'
  divUp(a, b) * b

proc orElse*[A](a, b: Option[A]): Option[A] =
  if (a.isSome()): a else: b

when not declared(parseDuration): # Odd code formatting to minimize diff v. mainLine
  const Whitespace = {' ', '\t', '\v', '\r', '\l', '\f'}

  func toLowerAscii(c: char): char =
    if c in {'A' .. 'Z'}:
      char(uint8(c) xor 0b0010_0000'u8)
    else:
      c

  func parseDuration*(s: string, size: var Duration): int =
    ## Parse a size qualified by simple time into `Duration`.
    ##
    runnableExamples:
      var res: Duration # caller must still know if 'b' refers to bytes|bits
      doAssert parseDuration("10H", res) == 3
      doAssert res == initDuration(hours = 10)
      doAssert parseDuration("64m", res) == 6
      doAssert res == initDuration(minutes = 64)
      doAssert parseDuration("7m/block", res) == 2 # '/' stops parse
      doAssert res == initDuration(minutes = 7) # 1 shl 30, forced binary metric
      doAssert parseDuration("3d", res) == 2 # '/' stops parse
      doAssert res == initDuration(days = 3) # 1 shl 30, forced binary metric

    const prefix = "s" & "mhdw" # byte|bit & lowCase metric-ish prefixes
    const timeScale = [1.0, 60.0, 3600.0, 86_400.0, 604_800.0]

    var number: float
    var scale = 1.0
    result = parseFloat(s, number)
    if number < 0: # While parseFloat accepts negatives ..
      result = 0 #.. we do not since sizes cannot be < 0
    else:
      let start = result # Save spot to maybe unwind white to EOS
      while result < s.len and s[result] in Whitespace:
        inc result
      if result < s.len: # Illegal starting char => unity
        if (let si = prefix.find(s[result].toLowerAscii); si >= 0):
          inc result # Now parse the scale
          scale = timeScale[si]
      else: # Unwind result advancement when there..
        result = start #..is no unit to the end of `s`.
      var sizeF = number * scale + 0.5 # Saturate to int64.high when too big
      size = seconds(int(sizeF))
