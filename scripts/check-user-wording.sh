#!/bin/zsh
# Wording guard (design/DESIGN.md §6 Voice and copy, Name and marks). Two checks on Swift string literals:
# 1. Text the user reads says "session", never "conversation": a literal under Sources/LoomCatalogUI or
#    Sources/loom-app that contains "conversation" or "Conversation" as a word fails.
# 2. The app is named Sphyrna (D-77, D-83): a literal under Sources/LoomCatalogUI, loom-app, LoomCore, LoomChat,
#    LoomLaunchOptions, LoomRemora, LoomTerminal or loom-hook (the CLI helper's messages, from 1.8.0) that contains
#    the word "Loom" (or, from 1.7.1, a lowercase "loom" that is a word of its own: a plugin or style name, a branch
#    prefix, a client name) fails, multi-line literals included. Paths,
#    ids and code names keep Loom (Loom.app, Loom-Dev, LoomRunHost.app, local.loom.desktop): a path to a bundle
#    and a hyphened or longer name are not the word.
# A hit passes when its "path:line:code" text matches an extended regex in scripts/check-user-wording.allow
# (one per line; evidence keys, identifiers, data folder names). String interpolations and comment-only lines
# are ignored. Plain grep/perl on the sources (the clean loom tree has no scripts, so this is a script check).
# Usage: scripts/check-user-wording.sh   (exit 0 clean, 1 with violations listed)
set -euo pipefail

root=${0:A:h:h}
allow=${0:A:h}/check-user-wording.allow
cd "$root"

# Drops the hits an allow line covers.
allowed() { if [[ -f $allow ]]; then grep -vEf <(grep -vE '^[[:space:]]*(#|$)' "$allow") || true; else cat; fi; }

hits=$(grep -rnE '[Cc]onversation' Sources/LoomCatalogUI Sources/loom-app --include='*.swift' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | perl -ne 'if (/^([^:]+:\d+:)(.*)$/) { my ($p, $l) = ($1, $2); my $s = $l; 1 while $s =~ s/\\\([^()]*\)//; print $_ if $s =~ /"[^"]*(?<![\w])[Cc]onversations?(?![\w])[^"]*"/; }' \
  | allowed || true)

if [[ -n $hits ]]; then
  echo "User-visible wording: use \"session\", not \"conversation\" in string literals (allowlist: scripts/check-user-wording.allow):" >&2
  print -r -- "$hits" >&2
  exit 1
fi
echo "wording guard: no \"conversation\" in user-visible literals"

# The word Loom: not after a letter, digit, "_", "." or "/", not before a letter, digit, "_" or "-", and not
# the start of a bundle name ("Loom.app", "Loom Dev.app").
name_dirs=(Sources/LoomCatalogUI Sources/loom-app Sources/LoomCore Sources/LoomChat Sources/LoomLaunchOptions Sources/LoomRemora
  Sources/LoomTerminal Sources/loom-hook)
files=(${(f)"$(find $name_dirs -name '*.swift' -type f | sort)"})
names=$(perl -e '
  my $word = qr{(?<![\w./])Loom(?![\w-]|\.app| Dev\.app)|(?<![\w./-])loom(?![\w.-])};
  for my $file (@ARGV) {
    open(my $in, "<", $file) or die "$file: $!";
    my $block = 0;
    while (my $line = <$in>) {
      chomp $line;
      my $code = $line;
      1 while $code =~ s/\\\([^()]*\)//;
      if ($block) {
        # Inside a multi-line literal: the line is text up to the closing quotes.
        my ($text, $close) = split(/"""/, $code, 2);
        print "$file:$.:$line\n" if $text =~ $word;
        $block = 0 if defined $close;
        next;
      }
      next if $code =~ m{^\s*//};
      my $opens = () = $code =~ /"""/g;
      if ($opens % 2) {
        my ($before, $after) = split(/"""/, $code, 2);
        print "$file:$.:$line\n" if $after =~ $word;
        $code = $before;
        $block = 1;
      }
      $code =~ s/"""//g;
      while ($code =~ /"((?:[^"\\]|\\.)*)"/g) {
        if ($1 =~ $word) { print "$file:$.:$line\n"; last; }
      }
    }
    close($in);
  }
' $files | allowed || true)

if [[ -n $names ]]; then
  echo "User-visible wording: the app is Sphyrna, not Loom, in string literals; paths, ids and code names keep Loom (allowlist: scripts/check-user-wording.allow):" >&2
  print -r -- "$names" >&2
  exit 1
fi
echo "wording guard: no \"Loom\" or lowercase \"loom\" word in user-visible literals"
