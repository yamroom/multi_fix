#!/usr/bin/perl
use strict;
use warnings;

# Simulate the provided file content
my $file_content = '
A = 1
B = 2
C = 3
D = "EQ"
.param SS = "cgdo_eq"

+ cctg = 1e-12       covl = 5e-17    sa = "question"

m1 d g s b n_p9_ulprvt_main w=w l=l
.model
lkvth0 = 5 dvt0 = 1
';

sub extract_assignments_from_string {
    my ($file_content) = @_;
    my @results;
    my @lines = split /\n/, $file_content;
    
    foreach my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;  # Trim whitespace from both ends
        next if $line eq '' or $line =~ /^[\s\#\.]/;  # Skip empty lines or lines starting with '#', or '.'

        if ($line =~ /^\+/ || $line =~ /^\.param/) {
            $line =~ s/^\+//;  # Remove '+' from start of lines, if present
            $line =~ s/^\.param//;  # Remove '.param' from start of lines, if present
        }

        my @parts = split /(?<!\w)(?=\w+\s*=)/, $line;  # Improve splitting logic
        foreach my $part (@parts) {
            if ($part =~ /(\w+)\s*=\s*(.+)/) {
                my $param = $1;
                my $value = $2;
                $value =~ s/\s+\w+\s*=.*$//;  # Trim any subsequent parameter starts
                $value =~ s/^\s+|\s+$//g;  # Trim leading and trailing spaces

                if ($value !~ /^'.*'$|^".*"$|^-?\d+(\.\d+)?([eE][-+]?\d+)?$/) {
                    $value = "'$value'";
                }

                push @results, "$param = $value";
            }
        }
    }
    return \@results;
}

# Run the extraction function and print the results
my $results = extract_assignments_from_string($file_content);
foreach my $result (@$results) {
    print "$result\n";
}