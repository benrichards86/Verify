#!/usr/bin/perl -w

use strict;

use Pod::Simple::HTML;

while (@ARGV > 0) {
    my $opt = shift @ARGV;
    if ($opt eq "-h") {
        print "get_readme.pl\n";
        print "Extracts README.pod from verify.pl.\n";
        print "\n";
        print "Usage:\n";
        print "  get_readme.pl [-h]\n";
        print "\n";
        print "Options:\n";
        print "  -h   Shows this help message.\n";
        print "\n";
        print "Written by Benjamin Richards, (c) 2013\n";
        print "Code adapted from Pod::Simple::HTML CPAN documentation.\n";
        exit;
    }
    else {
        die "Unknown option: $opt\n";
    }
}

my $p = Pod::Simple::HTML->new;
$p->output_string(\my $html);
$p->parse_file('verify.pl');
open my $out, '>', 'README.pod' or die "Cannot open 'out.html': $!\n";
print $out $html;
exit;
