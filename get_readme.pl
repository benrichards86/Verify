#!/usr/bin/perl -w
## Copyright (C) 2012,2013  Benjamin D. Richards
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License along
## with this program; if not, write to the Free Software Foundation, Inc.,
## 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

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
        print "Written by Benjamin Richards, (c) 2012,2013\n";
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
open my $out, '>', 'README.pod' or die "Cannot open 'README.pod': $!\n";
print $out $html;
exit;
