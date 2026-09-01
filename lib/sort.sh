#!/bin/bash
# lib/sort.sh — one field-based, stable, dash-last row reorder, used by every
# --sort flag in the product.
#
# WHY THIS IS ITS OWN FILE. `steward sessions --sort` (1503e29) grew this once,
# inline in cmd_sessions. The estate-listing form (`steward <estate> ls
# --sort`) needed the exact same reorder over a DIFFERENT row shape (a
# different table, a different delimiter, a different set of field numbers) —
# and a second hand-copied awk/sort pipeline is exactly the kind of duplication
# that drifts: one call site gets a bugfix, the other does not, and the two
# --sort flags quietly stop meaning the same thing. One function, called from
# both bin/steward (locally) and linux/estate-status.sh (remotely, over ssh,
# where THAT machine's own copy of this file runs).
#
# _field_sort_rows <field> [delim] — the row data on stdin, stably reordered by
# the given 1-indexed field, on stdout. delim defaults to a tab (bin/steward's
# TSV rows); estate-status.sh's table is '|'-delimited and passes that
# explicitly. LC_ALL=C: sort order must not depend on the operator's locale, or
# the same fixture would order two ways on two machines, and -s (stable) so two
# rows sharing a sort key keep the order the caller gave them rather than
# swapping on a whim.
#
# A ROW WHOSE FIELD IS EXACTLY "-" SORTS LAST, regardless of which field. "-"
# is this product's own placeholder for "no such value" (lib/sessions.sh uses
# it for SLUG on an old-shape row; linux/estate-status.sh uses it for MODEL) —
# and ASCII '-' collates BEFORE every letter and digit in the C locale, so a
# plain sort would put every row with NO value first, ahead of every row that
# actually has the one being sorted on. That reads backwards to an operator:
# the rows carrying real data belong first, the placeholders trail behind.
#
# THE OUTER WRAPPER IS ALWAYS TAB-DELIMITED, regardless of the CALLER's delim.
# rank/field/rest are joined with a literal tab and sorted/cut on it — $0
# (the "rest") still carries the row in the caller's own delimiter untouched,
# so a '|'-delimited input comes back out '|'-delimited. This only breaks if a
# row's own field VALUES contain a literal tab, which none of this product's
# row shapes ever do (registry values are single-line, and lib/sessions.sh's
# own TSV rows already escape tab/newline before they reach here).
_field_sort_rows() {
  local field="$1" delim="${2:-$'\t'}"
  awk -F "$delim" -v f="$field" '
    NF == 0 { next }
    { rank = ($f == "-") ? 1 : 0; print rank "\t" $f "\t" $0 }
  ' | LC_ALL=C sort -t $'\t' -s -k1,1 -k2,2 | cut -f3-
}
