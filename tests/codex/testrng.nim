import std/unittest
import std/sequtils
import std/sets

import ../../codex/rng

suite "Random Number Generator (RNG)":
  let rng = Rng.instance()

  test "should sample with replacement":
    let elements = toSeq(1 .. 10)

    let sample = rng.sample(elements, n = 15, replace = true)
    check sample.len == 15
    for element in sample:
      check element in elements

  test "should sample without replacement":
    let elements = toSeq(1 .. 10)

    # If we were not drawing without replacement, there'd be a 1/2 chance
    # that we'd draw the same element twice in a sample of size 5. 
    # Running this 40 times gives enough assurance.
    var seen: array[10, bool]
    for i in 1 .. 40:
      let sample = rng.sample(elements, n = 5, replace = false)

      check sample.len == 5
      check sample.toHashSet.len == 5

      for element in sample:
        seen[element - 1] = true

    # There's a 1/2 chance we'll see an element for each draw we do.
    # After 40 draws, we are reasonably sure we've seen every element.
    for seen in seen:
      check seen
