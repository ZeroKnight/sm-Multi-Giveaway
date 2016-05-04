#!/usr/bin/env perl

# Unit test for Sourcemod plugin Multi-Giveaway
#
# Check for discrepencies in translation phrase usage. Reports potential typos.

use strict;
use warnings;
use v5.14;

use File::Basename;

my @cfiles = ('multi-giveaway.sp');
my @tfiles = ('Multi-Giveaway.phrases.txt');
my $tpath  = 'translations';
my @phrases;
my %report = (
  valid   => {}, # Phrases used that exist in a translation file
  invalid => {}, # Phrases used that do not exist in a translation file
  unused  => []  # Phrases available but not used
);

chdir dirname($0);

# Scan our translation file(s)
foreach my $f (@tfiles)
{
  open my $fh, '<', "../$tpath/$f";
  while (<$fh>)
  {
    push @phrases, $1 if $_ =~ /^\s\s"(.+)"$/;
  }
  close $fh;
}

# Walk our code and generate a report
foreach my $f (@cfiles)
{
  my $regex = qr/"(MG_[^"]+)",?/;
  open my $fh, '<', "../$f";
  while (my $line = <$fh>)
  {
    #next unless $line =~ /%t/;
    if ($line !~ /\/\/\s*.*$regex/)
    {
      my @matches = $line =~ /"(MG_[^"]+)",?/g;
      foreach my $m (@matches)
      {
        if (grep {$_ eq $m} @phrases)
        {
          $report{valid}{$.} //= [];
          push @{$report{valid}{$.}}, $m;
        }
        else
        {
          $report{invalid}{$.} = $1;
        }
      }
    }
  }
  close $fh;
}

# Check for unused translations
@{$report{unused}} = @phrases;
foreach my $v (values %{$report{valid}})
{
  foreach my $p (@$v)
  {
    @{$report{unused}} = grep {$_ ne $p} @{$report{unused}};
  }
}

# Print report
my $valid = keys %{$report{valid}};
my $invalid = keys %{$report{invalid}};
my $unused = @{$report{unused}};
my $total_uses = (keys %{$report{valid}}) + (keys %{$report{invalid}});

print "$total_uses phrase uses out of " . scalar @phrases . " total\n";
print($invalid ? '✗' : '✓', " $invalid invalid\n");
print($unused  ? '!' : '✓', " $unused unused\n");

print "Invalid uses:\n" if $invalid;
while (my ($line, $p) = each %{$report{invalid}})
{
  print "[*] Line $line: $p\n";
}
do { local $" = ', '; print "Unused: @{$report{unused}}\n" if $unused };

# Exit status for git hook
exit 1 if $invalid;

