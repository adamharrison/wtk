#!/usr/bin/perl
# Use on onelua.c to compile it into a single file.

use strict;
use warnings;

use File::Slurp;
use File::Basename qw(dirname basename);

my $file = $ARGV[0];

sub process_file {
  my ($file, $hash, $depth) = @_;
  open(my $fh, "<", $file) or die "can't open file $file: $!";
  my $dir = dirname($file);
  my $open = 0;
  while (my $line = <$fh>) {
    $line =~ s/\/\*.*?\*\///g;
    if ($open && $line =~ m/^.*?\*\//) {
      $line =~ s/^.*?\*\///;
      $open = 0;
    }
    if (!$open && $line =~ m/\/\*.*?$/) {
      $open = 1;
      $line =~ s/\/\*.*?$//;
      print $line . "\n" if $line !~ m/^\s*$/;
    }
    if (!$open) {
      if ($line =~ m/^#include\s+"(\S+)"/) {
        if (!$hash->{$1} && (-f $dir . "/" . $1)) {
          $hash->{$1} = 1;
          process_file($dir . "/" . $1, $hash, $depth + 1);
        }
      } elsif ($line !~ m/^\s*$/) {
        print $line;
      }
    }
  }
}

print "#define MAKE_LIB\n";
process_file($file, { }, 0);
