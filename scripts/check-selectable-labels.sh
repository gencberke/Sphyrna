#!/bin/zsh
# Selectable-text label guard (docs/ARCHITECTURE.md §12.1). On macOS 27 a SwiftUI Text with `.textSelection(.enabled)` is
# an AppKit element; an `.accessibilityLabel` on that same element makes SwiftUI install a label override on it and then
# resolve the label by asking the element again, which recurses until the main thread's stack runs out. An assistive
# client copying the hierarchy (VoiceOver, automation, window tools) took the signed app down twice this way on 29 Oct
# (a delegation request's message preview). The label must belong to a wrapper element instead:
#   Text(x).textSelection(.enabled) … .accessibilityElement(children: .contain).accessibilityLabel(…)
# A modifier chain (lines that start with "." continue the line before; comment-only lines are skipped) under
# Sources/LoomCatalogUI or Sources/loom-app fails when it holds `.textSelection(.enabled)` and an `.accessibilityLabel(`
# with no `.accessibilityElement(` between the selection and the label.
# Usage: scripts/check-selectable-labels.sh   (exit 0 clean, 1 with violations listed)
set -euo pipefail

root=${0:A:h:h}
cd "$root"

files=(${(f)"$(find Sources/LoomCatalogUI Sources/loom-app -name '*.swift' -type f | sort)"})
hits=$(perl -e '
  for my $file (@ARGV) {
    open(my $in, "<", $file) or die "$file: $!";
    my @chain; my $start = 0; my $number = 0;
    my $flush = sub {
      return unless @chain;
      my $text = join("\n", @chain);
      my $label = index($text, ".accessibilityLabel(");
      my $selection = index($text, ".textSelection(.enabled)");
      if ($label >= 0 && $selection >= 0) {
        my $wrapper = rindex($text, ".accessibilityElement(", $label);
        print "$file:$start: a selectable Text carries its own accessibility label\n"
          unless $wrapper > $selection && $selection < $label;
      }
      @chain = ();
    };
    while (my $line = <$in>) {
      $number++;
      chomp $line;
      next if $line =~ /^\s*\/\//;
      if ($line =~ /^\s*\./ && @chain) { push @chain, $line; next; }
      $flush->();
      @chain = ($line); $start = $number;
    }
    $flush->();
  }
' $files || true)

if [[ -n $hits ]]; then
  echo "Selectable text: put the accessibility label on a wrapper, .accessibilityElement(children: .contain).accessibilityLabel(…):" >&2
  print -r -- "$hits" >&2
  exit 1
fi
echo "selectable-label guard: no selectable Text carries its own accessibility label"
