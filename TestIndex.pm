## TestIndex.pm
## Indexes tests and parses test files. Supports multiple tests per file.
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
use List::Uniq ':all';
use DB_File;
use TestFileParser;

package verify::TestIndex;

# Function prototypes
sub TestIndex::set_testsdir( $ );
sub TestIndex::recursive_scan( $$ );
sub TestIndex::find_test( $$ );
sub TestIndex::test_exists( $$$;$ );
sub TestIndex::get_test_file( $$ );
sub TestIndex::quick_parse_file( $ );
sub TestIndex::get_test( $$$;$ );
sub TestIndex::list_tests();
sub update_index( $ );

# Root directory where test files will live under
my $testsdir = "";

# To set testsdir
sub TestIndex::set_testsdir($) {
    $testsdir = "$_[0]";
}

### recursive_scan() ###
# Recursively scans from the root directory for *.test files, and calls a handler function on each file.
# Parameters:
#   - Current directory to search under
#   - Alias to anonymous function to call on each file found
###
sub TestIndex::recursive_scan($$) {
    my ($root_dir, $handler) = @_;

    # Index any files in subdirectories
    my @dirs = grep{ -d } glob $root_dir.'/*';
    foreach my $curr_dir (@dirs) {
        TestIndex::recursive_scan($curr_dir, $handler);
    }

    # Index any files in this directory
    foreach my $curr_file (<$root_dir/*.test>) {
        $curr_file =~ s|$testsdir\/||;
        $handler->($curr_file);
    }
}

### update_index() ###
# Updates the index in-place.
# Parameters:
#   - Current directory to search under
# Returns:
#   - Number of tests added
#   - Number of tests removed
###
sub update_index($) {
    my ($added_count, $removed_count) = (0, 0);
    my ($root_dir) = @_;

    verify::log_status("Updating index... ");

    # Do a check for exist and remove those that don't exist anymore, storing those that do...
    my %test_db;
    tie %test_db, "DB_File", "$ENV{PRJ_HOME}/.verify/index.db", DB_File::O_CREAT|DB_File::O_RDWR, 0666, $DB_File::DB_BTREE or verify::tdie("Cannot tile filename: %!\n");
    foreach my $k (keys %test_db) {
        if (!-e $testsdir.'/'.$test_db{$k}) {
            delete $test_db{$k};
            $removed_count ++;
        }
    }

    # Now, the index contains only previously indexed tests that still exist.
    my @currfiles_arr = List::Uniq::uniq(values %test_db);
    my %currfiles;

    # Scan existing files for tests that aren't yet indexed...
    foreach my $currfile (@currfiles_arr) {
        $currfiles{$currfile} = 1; # In the meantime, store off our files into a hash for reference later, if we need it.
        my @curr_tests = TestIndex::quick_parse_file($testsdir.'/'.$currfile);
        if (@curr_tests) {
            foreach my $test (@curr_tests) {
                if (! exists($test_db{$test->{'config'}.'::'.$test->{'name'}})) {
                    # Didn't index this test yet! Add it to our index.
                    $test_db{$test->{'config'}.'::'.$test->{'name'}} = $currfile;
                    $added_count++;
                }
            }
        }
        else {
            # Something went horribly wrong. The file should have been already verified to exist.
            verify::tdie("Unable to open test file when indexing tests!\n$!\n File: $testsdir/$currfile\n");
        }
    }

    # Now, the index contains all tests that exist in previously indexed test files.
    # Scan the file system for any test files we haven't yet indexed...
    my $index_count = 0;
    my $callback = sub {
        my $currfile = $_[0];

        # Checks if current found file is already indexed. If not, add its tests.
        my $found = 0;
        foreach my $curr (values %test_db) {
            $found = 1 if ($curr eq $currfile);
        }
        if (!$found) {
            my @tests = TestIndex::quick_parse_file($testsdir.'/'.$currfile);
            if (@tests) {
                foreach my $test (@tests) {
                    $test_db{$test->{'config'}.'::'.$test->{'name'}} = $currfile;
                    $added_count ++;
                }
            }
            else {
                verify::tdie("Error reading test file!\n$!\n File: $testsdir/$currfile\n");
            }
        }
    };

    TestIndex::recursive_scan($testsdir, $callback);
    
    # Index is updated!
    untie %test_db;
    verify::log_status("Done!\n");

    return ($added_count, $removed_count);
}

### find_test() ###
# Searches the index for the test specified.
# Parameters:
#   - Config for the test
#   - Name of the test
# Returns:
#   - Filename of the test file, if found. Empty string if not found.
###
sub TestIndex::find_test($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    verify::log_status("Looking up test file in index... ");
    my %test_db;
    tie %test_db, "DB_File", "$ENV{PRJ_HOME}/.verify/index.db", DB_File::O_CREAT|DB_File::O_RDWR, 0666, $DB_File::DB_BTREE or verify::tdie("Cannot tile filename: %!\n");
    if (exists $test_db{$config.'::'.$testname}) { # We found it! Close file and exit loop
        $testfile_str = $test_db{$config.'::'.$testname};
        verify::log_status("Found. [$testfile_str]\n");
    }

    if ($testfile_str eq "") {
        verify::log_status("Not found!\n");
    }
    
    return $testfile_str;
}

### test_exists() ###
# Verifies that the test we want exists at the location specified. Searches only the first 
# test block encountered.
# Parameters:
#   - Filename (incl. path) of .test file to look inside
#   - Test name
#   - Test configuration
#   - Line number to jump to in .test file (optional)
# Returns:
#   - 1 for found, 0 for not found.
###
sub TestIndex::test_exists( $$$;$ ) {
    my ($file, $name, $config, $line_number);
    my $found_name = 0;

    if (scalar(@_) > 3) {
        ($file, $name, $config, $line_number) = @_;
        TestFileParser::seek($line_number) or return 0;
    }
    else {
        ($file, $name, $config) = @_;
    }

    TestFileParser::open($testsdir.'/'.$file) or return 0;
    
    while ((my @instr = TestFileParser::get_next_instruction()) > 0) {
        if ($instr[0] eq "endtest") {
            if (defined $line_number) {
                TestFileParser::close();
                return 0;
            }
            else {
                $found_name = 0;
            }
        }
        elsif ($instr[0] eq "test" && $instr[3] eq $name) {
            $found_name = 1;
        }
        elsif ($instr[0] eq "config" && $instr[3] eq $config) {
            if ($found_name == 1) {
                TestFileParser::close();
                return 1;
            }
        }
    }
    
    TestFileParser::close();
    return 0;
}

### get_test_file() ###
# Finds the path to the test file in which the provided config::test pair is defined.
# Parameters:
#   - Configuration string for the test
#   - Name of the test
# Returns:
#   - Relative path and filename (under $testsdir) to the test file.
###
sub TestIndex::get_test_file($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    my $index_up2date = 0;

    # First, check if index exists
    if (!-e $ENV{'PRJ_HOME'}.'/.verify/index.db') {
        # Index doesn't exist: build it!
        verify::log_status("Index not found! Doing initial build...\n");
        
        my $indexed_count = 0;
        mkdir "$ENV{PRJ_HOME}/.verify" unless (-d "$ENV{PRJ_HOME}/.verify");
        
        my %index_hash;
        tie %index_hash, "DB_File", "$ENV{PRJ_HOME}/.verify/index.db", DB_File::O_CREAT|DB_File::O_RDWR, 0666, $DB_File::DB_BTREE or verify::tdie("Cannot tile filename: %!\n");

        my $callback = sub {
            my @curr_tests = TestIndex::quick_parse_file($testsdir.'/'.$_[0]);
            if (@curr_tests) {
                foreach my $curr_test (@curr_tests) {
                    my $idx_key = $curr_test->{'config'}.'::'.$curr_test->{'name'};
                    my $idx_value = $_[0];

                    $index_hash{$idx_key} = $idx_value;
                    $indexed_count ++;
                }
            }
            else {
                verify::tdie("Unable to open test file when creating index!\n$!\n File: $testsdir/$_[0]\n");
            }
        };
        
        TestIndex::recursive_scan($testsdir, $callback);
        verify::log_status("Indexed $indexed_count tests.\n");

        untie %index_hash;
        $index_up2date = 1;
    }

    # Now, open index and look for test
    $testfile_str = TestIndex::find_test($config, $testname);

    # Check if we found the file. If not, update the index (if not up to date).
    if ($testfile_str eq "" || !-e $testsdir.'/'.$testfile_str) { # It will remain unset if we didn't find it. Also trigger if it's indexed but the test file doesn't exist.
        if ($index_up2date) {
            verify::tlog(1, "The test ".$config."::".$testname." could not be found!\n");
            return "";
        }
        else {
            # Index may not be up to date, so update the index now and then search again!
            verify::log_status("Test not found in index. Maybe the index isn't up to date?\n");
            my ($added_count, $removed_count) = update_index($testsdir);
            $index_up2date = 1;
            verify::log_status("Updated index: added $added_count, removed $removed_count\n");
        }

        # Now that the index is updated, search for the test again...
        $testfile_str = TestIndex::find_test($config, $testname);

        if ($testfile_str eq "") { # Still can't find it? Then it must not exist.
            verify::tlog(1, "The test ".$config."::".$testname." could not be found!\n");
            return "";
        }
    }
    else {
        # We found the test in the index, but now we need to make sure it actually exists where it says it does.
        verify::log_status("Checking indexed file location for test... ");
        my $found = TestIndex::test_exists($testfile_str, $testname, $config);

        # Couldn't find the test where the index specified! Reindex and look again.
        if ($found == 0) {
            verify::log_status("Not found!\n");
            if ($index_up2date == 0) {
                my ($added_count, $removed_count) = update_index($testsdir);
                $index_up2date = 1;
                verify::log_status("Updated index: added $added_count, removed $removed_count\n");

                $testfile_str = TestIndex::find_test($config, $testname);
                if ($testfile_str eq "") { # Still not found? It doesn't exist.
                    verify::tlog(1, "The test ".$config."::".$testname." could not be found!\n");
                    return "";
                }
            }
        }
        else {
            verify::log_status("Test exists.\n");
        }
    }

    return $testfile_str;
}

### quick_parse_file() ###
# Does a minimal parse operation on a test file, only extracing test name, configuration, and description for all tests in the file.
# Parameters:
#   - Filename (with path) of the test file to parse.
# Returns:
#   - Reference to an array of {name,config,description} hashes.
###
sub TestIndex::quick_parse_file($) {
    my ($testfile) = @_;
    my @test_list = ();

    verify::log_status("Parsing test file [".$testfile."].\n");
    TestFileParser::open($testfile) or verify::tdie("Unable to open test file!\n$!\n File: $testfile\n");

    my $scope = -1;
    my ($name, $config, $description, $line_number);
    my $required_flags = 0;

    # Loop through whole file, extracting name, config, and description.
    while ((my @curr = TestFileParser::get_next_instruction()) > 0) {
        if ($scope == -1) {
            if ($curr[0] eq 'test') {
                $name = $curr[3];
                $scope = $curr[2];
                $required_flags |= 1;
                $line_number = TestFileParser::get_current_position() - 1;
            }
        }
        else {
            if ($curr[0] eq 'config') {
                $config = $curr[3];
                $required_flags |= 0x4;
            }
            elsif ($curr[0] eq 'description') {
                $description = $curr[3];
                $required_flags |= 0x2;            
            }
            elsif ($curr[0] eq 'endtest') {
                # Check for required fields
                if ($required_flags != 0x7) {
                    my $msg = "";
                    $msg = "$msg Required field 'name' was not found.\n" if !($required_flags & 0x1);
                    $msg = "$msg Required field 'description' was not found.\n" if !($required_flags & 0x2);
                    $msg = "$msg Required field 'config' was not found.\n" if !($required_flags & 0x4);
                    verify::tlog(1, "Error: One or more required fields were not found in the test file!\n$msg");
                }
                else {
                    my $curr_test = {'name' => $name, 'config' => $config, 'description' => $description, 'line' => $line_number};
                    push(@test_list, $curr_test);
                }

                undef $name;
                undef $config;
                undef $description;
                undef $line_number;
                $required_flags = 0;
                $scope = -1;
            }
        }
    } 

    TestFileParser::close();

    return @test_list;
}

sub init_test() {
    my $test = {"name" => "",          # Required: Identifies the test
                "description" => "",   # Required: Describes the test
                "config" => "",        # Required: Testbench config associated with the test
                "build.args" => "",    # These are custom parameters passed directly to the build tool
                "run.args" => "",      # These are custom parameters passed directly to the run tool
                "params" => "",        # This is the list of test parameters passed in the file and/or on the command-line as comma-separated values
                "define" => {},        # Used to define custom parameters for both build and run steps
                "build.define" => {},  # Same as above, but only build step
                "run.define" => {}};   # Same as above, but only run step
    
    return $test;
}

### parse_test_file() ###
# Parses test arguments specified in *.test files.
# Parameters:
#   - Filename (with relative path) of the test file to parse.
#   - Configuration of the test to load
#   - Name of the test to load
#   - Parameters passed on command-line (optional)
# Returns:
#   - A reference to the test information stored in a relational array in memory
###
sub TestIndex::get_test($$$;$) {
    my $test = init_test();

    my $required_flags = 0;

    my $testfile = $testsdir.'/'.$_[0];
    my $config = $_[1];
    my $name = $_[2];
    my @testparams = @{$_[3]} if (@_ > 3);
    
    my $msg = "";

    verify::log_status("Parsing test file [".$testfile."] for test: ".$config."::".$name."\n");
    TestFileParser::open($testfile) or verify::tdie("Unable to open test file!\n$!\n File: $testfile\n");
    
    my $scope = -1;
    my @curr = ();

    do {
        @curr = TestFileParser::get_next_instruction();

        if (@curr == 0) {
            # TODO: error
        }

        if ($scope == -1) {
            if ($curr[0] eq 'test' && $curr[3] eq $name) {
                $test->{'name'} = $curr[3];
                $scope = $curr[2];
                $required_flags |= 1;
            }
        }
        else {
            if ($curr[0] eq 'config') {
                if ($curr[3] ne $config) {  # Not config we want, so this must not be the test we care about. Back to the start.
                    $scope = -1;
                    $test = init_test();
                    $required_flags = 0;
                }
                else {
                    $test->{'config'} = $curr[3];
                    $required_flags |= 0x4;
                }
            }
            elsif ($curr[0] eq 'description') {
                $test->{'description'} = $curr[3];
                $required_flags |= 0x2;            
            }
            elsif ($curr[0] eq 'params') {
                if ($curr[5] eq '=') {
                    $test->{'params'} = $curr[3];
                }
                elsif ($curr[5] eq '+=') {
                    $test->{'params'} = $test->{'params'}.$curr[3];
                }
                else {
                    # TODO: error
                }
            }
            elsif ($curr[0] eq 'build.args') {
                if ($curr[5] eq '=') {
                    $test->{'build.args'} = $curr[3];
                }
                elsif ($curr[5] eq '+=') {
                    $test->{'build.args'} = $test->{'build.args'}.' '.$curr[3];
                }
                else {
                    # TODO: error
                }
            }
            elsif ($curr[0] eq 'run.args') {
                if ($curr[5] eq '=') {
                    $test->{'run.args'} = $curr[3];
                }
                elsif ($curr[5] eq '+=') {
                    $test->{'run.args'} = $test->{'run.args'}.' '.$curr[3];
                }
                else {
                    # TODO: error
                }
            }
            elsif ($curr[0] eq 'define') {
                if (!defined $curr[1]) {
                    if ($curr[5] eq '=') {
                        $test->{'define'}->{$curr[3]} = $curr[4];
                    }
                    elsif ($curr[5] eq '+=') {
                        $test->{'define'}->{$curr[3]} = $test->{'define'}->{$curr[3]}.' '.$curr[4];
                    }
                    else {
                        # TODO: error
                    }
                }
                elsif ($curr[1] eq 'build') {
                    if ($curr[5] eq '=') {
                        $test->{'build.define'}->{$curr[3]} = $curr[4];
                    }
                    elsif ($curr[5] eq '+=') {
                        $test->{'build.define'}->{$curr[3]} = $test->{'build.define'}->{$curr[3]}.' '.$curr[4];
                    }
                    else {
                        # TODO: error
                    }
                }
                elsif ($curr[1] eq 'run') {
                    if ($curr[5] eq '=') {
                        $test->{'run.define'}->{$curr[3]} = $curr[4];
                    }
                    elsif ($curr[5] eq '+=') {
                        $test->{'run.define'}->{$curr[3]} = $test->{'run.define'}->{$curr[3]}.' '.$curr[4];
                    }
                    else {
                        # TODO: error
                    }
                }
            }
        }
    } until ($scope != -1 && $curr[0] eq 'endtest');

  L1_FIN:
    TestFileParser::close();

    # Check for required fields
    if ($required_flags != 0x7) {
        $msg = "";
        $msg = "$msg Required field 'name' was not found.\n" if !($required_flags & 0x1);
        $msg = "$msg Required field 'description' was not found.\n" if !($required_flags & 0x2);
        $msg = "$msg Required field 'config' was not found.\n" if !($required_flags & 0x4);
        verify::tdie("One or more required fields were not found in the test file!\n$msg");
    }

    # Handle test parameters (custom, built-in, and command-line)    
    if ($test->{'params'} ne "") {
        $test->{'params'} = $test->{'params'}.','.join(',', @testparams) if (@testparams);
    }
    else {
        $test->{'params'} = join(',', @testparams) if (@testparams);
    }
    
    # Handle test params that were defined in the test file, before calling user code, according to definition specified
    foreach my $p (split(',', $test->{'params'})) {
        # Split into (pname, pkey), where params can be 'pname=pkey', or just 'pname' (with 'pkey' being empty string).
        my ($pname, @pkey_l) = split('=', $p);
        my $pkey = join('=', @pkey_l);

        # Check for values.
        if (exists $test->{'define'}->{$pname}) {
            my $param_for_test = $test->{'define'}->{$pname};
            $param_for_test = TestFileParser::parse_parameter($param_for_test, $pkey);
            $test->{'build.args'} = $test->{'build.args'}.' '.$param_for_test;
            $test->{'run.args'} = $test->{'run.args'}.' '.$param_for_test;
        }
        elsif (exists $test->{'build.define'}->{$pname}) {
            my $param_for_test = $test->{'build.define'}->{$pname};
            $param_for_test = TestFileParser::parse_parameter($param_for_test, $pkey);
            $test->{'build.args'} = $test->{'build.args'}.' '.$param_for_test;
        }
        elsif (exists $test->{'run.define'}->{$pname}) {
            my $param_for_test = $test->{'run.define'}->{$pname};
            $param_for_test = TestFileParser::parse_parameter($param_for_test, $pkey);
            $test->{'run.args'} = $test->{'run.args'}.' '.$param_for_test;
        }
        
    }
    
    # Save off string of command line for logging purposes:
    $test->{'logstr'} = $test->{'config'}.'::'.$test->{'name'}.(@testparams ? ','.join(',', @testparams) : '');

    return $test;
}

### list_tests() ###
# Does a recursive search under the tests root directory and displays each tests' config, name, and description in a list.
# Note: This function does not use the index file.
###
sub TestIndex::list_tests() {
    my $found_tests = 0;
    my $callback = sub {
        my @curr_tests = TestIndex::quick_parse_file($testsdir.'/'.$_[0]);
        if (@curr_tests) {
            foreach my $curr_test (@curr_tests) {
                verify::tlog(0, " ".$curr_test->{'config'}."::".$curr_test->{'name'}." - ".$curr_test->{'description'}."\n");
                $found_tests ++;
            }
        }
        else {
            verify::tdie("Unable to open test file when listing tests!\n$!\n File: $testsdir/$_[0]\n");
        }
    };

    verify::log_status("Finding all test files...\n");
    verify::tlog(0, "Listing all available tests:\n");
    verify::tlog(0, "----------------------------\n");
    TestIndex::recursive_scan($testsdir, $callback);
    verify::log_status("Found $found_tests tests.\n");
    verify::tlog(0, "End test list.\n");
}

1;
