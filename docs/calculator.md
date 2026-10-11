# Calculator and local calculation history

The front screen is an ordinary calculator: full horizontally scrollable
expression above a live result, digit grouping, sign toggle, percentage,
backspace, result copying and a History button. No chat/profile labels appear
on this screen. The existing unlock codes and biometric gate are retained;
triggering that gesture clears the visible expression before navigating and
never creates a calculation-history event. This is UI discretion, not a promise
that the installed application is undetectable or a security-model change.

## Arithmetic

- All entered terms are retained: `12+12+13+78-60 = 55`.
- Standard precedence: `2+3×4 = 14`. Operators entered consecutively replace the
  pending operator. Use `±` for a negative operand.
- `%` divides the preceding number by 100: `200×10% = 20`.
- `=` completes and records a calculation. Repeated `=` does not duplicate it.
- After `=`, an operator continues from the result; a digit begins a new entry.
  Backspace reopens the original expression for editing.
- At most 15 input digits per number and 300 expression characters. Arithmetic
  uses floating point with results rounded to 15 significant digits; it is not
  an arbitrary-precision financial ledger. Very large/small values use scientific
  notation. Divide-by-zero/nonfinite results are errors and are not saved.

## History

The last 200 completed calculations are stored in `calculator_history.json` in
the platform application-support directory using path_provider. This dependency
was already present transitively; it is now declared directly (no version bump).
This file is independent of Firebase, pairing and profile state. No Firebase
writes are made by calculation history. Uninstalling/clearing app data may remove
it; OS-managed backups remain subject to device settings.

Each entry contains expression, result and timestamp. Tap it to edit the original
expression; its menu offers Use result, Copy calculation and Delete. Clear all
requires confirmation. Restoring a saved expression/result does not execute
unlock detection. Genuine arithmetic that *produces* a number equal to an unlock
code is still an ordinary calculation; raw unlock keystrokes are never recorded.

Writes are serialized and replaced atomically. Corrupt files are reported, not
silently overwritten. A failed save shows a warning and labels in-memory history
as session-only. History is plain local calculation data, not encrypted storage
for sensitive records.

## Verification

Targeted calculator tests cover chained expressions, precedence, decimal rounding,
signs, percentages, divide-by-zero recovery, limits, unlock/display clearing,
restore workflow boundaries, file persistence, queued writes, corruption,
write failure, clear confirmation and narrow/landscape layout. Existing widget
regressions also exercise calculator navigation and the original arithmetic cases.
Local rendered before/after captures were inspected; no CI/build was dispatched.
Physical-device persistence after process kill and clipboard behavior still need
an Android smoke test.
