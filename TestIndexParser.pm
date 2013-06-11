# TestIndexParser.pm
# Indexes tests and parses test files. Supports multiple tests per file.
# Benjamin Richards, (c) 2012

use strict;
use Tie::File;
use List::Uniq ':all';
use DB_File;

package verify::TestIndexParser;

# Function prototypes
sub TestIndexParser::set_testsdir( $ );
sub TestIndexParser::recursive_scan( $$ );
sub TestIndexParser::update_index( $ );
sub TestIndexParser::prune_comments( $ );
sub TestIndexParser::find_test( $$ );
sub TestIndexParser::get_test_file( $$ );
sub TestIndexParser::quick_parse_file( $ );
sub TestIndexParser::parse_test_file( $$$;$ );
sub TestIndexParser::list_tests( );

# Root directory where test files will live under
my $testsdir = "";

# To set testsdir
sub TestIndexParser::set_testsdir($) {
    $testsdir = $_[0];
                                  }

### recursive_scan() ###
# Recursively scans from the root directory for *.test files, and calls a handler function on each file.
# Parameters:
#   - Current directory to search under
#   - Alias to anonymous function to call on each file found
###
sub TestIndexParser::recursive_scan($$) {
    my ($root_dir, $handler) = @_;

    # Index any files in subdirectories
    my @dirs = grep{ -d } glob $root_dir.'/*';
    foreach my $curr_dir (@dirs) {
        TestIndexParser::recursive_scan($curr_dir, $handler);
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
sub TestIndexParser::update_index($) {
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
        my @curr_tests = TestIndexParser::quick_parse_file($testsdir.'/'.$currfile);
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
            verify::tdie("Unable to open test file!\n$!\n File: $testsdir/$currfile\n");
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
            my @tests = TestIndexParser::quick_parse_file($testsdir.'/'.$currfile);
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

    TestIndexParser::recursive_scan($testsdir, $callback);
    
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
sub TestIndexParser::find_test($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    verify::log_status("Searching index for test... ");
    my %test_db;
    tie %test_db, "DB_File", "$ENV{PRJ_HOME}/.verify/index.db", DB_File::O_CREAT|DB_File::O_RDWR, 0666, $DB_File::DB_BTREE or verify::tdie("Cannot tile filename: %!\n");
    if (exists $test_db{$config.'::'.$testname}) { # We found it! Close file and exit loop
        verify::log_status("Found it!\n");
        $testfile_str = $test_db{$config.'::'.$testname};
        #close(IN);
    }

    if ($testfile_str eq "") {
        verify::log_status("Not found!\n");
    }
    
    return $testfile_str;
}

### get_test_file() ###
# Finds the path to the test file in which the provided config::test pair is defined.
# Parameters:
#   - Configuration string for the test
#   - Name of the test
# Returns:
#   - Relative path and filename (under $testsdir) to the test file.
###
sub TestIndexParser::get_test_file($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    my $index_up2date = 0;

    # First, check if index exists
    if (!-e $ENV{'PRJ_HOME'}.'/.verify/index.db') {
        # Index doesn't exist: build it!
        verify::log_status("Index not found! Doing initial build...\n");
        
        my $indexed_count = 0;
        mkdir "$ENV{PRJ_HOME}/.verify" unless (-d "$ENV{PRJ_HOME}/.verify");
        
        # DEBUG testing Berkely DB file format
        my %index_hash;
        tie %index_hash, "DB_File", "$ENV{PRJ_HOME}/.verify/index.db", DB_File::O_CREAT|DB_File::O_RDWR, 0666, $DB_File::DB_BTREE or verify::tdie("Cannot tile filename: %!\n");

        my $callback = sub {
            my @curr_tests = TestIndexParser::quick_parse_file($testsdir.'/'.$_[0]);
            if (@curr_tests) {
                foreach my $curr_test (@curr_tests) {
                    my $idx_key = $curr_test->{'config'}.'::'.$curr_test->{'name'};
                    my $idx_value = $_[0];

                    $index_hash{$idx_key} = $idx_value;
                    verify::tlog(0, "$idx_key exists : $index_hash{$idx_key}\n") if $index_hash{$idx_key};
                    $indexed_count ++;
                }
            }
            else {
                verify::tdie("Unable to open test file!\n$!\n File: $testsdir/$_[0]\n");
            }
        };
        
        TestIndexParser::recursive_scan($testsdir, $callback);
        verify::log_status("Indexed $indexed_count tests.\n");

        untie %index_hash;
        $index_up2date = 1;
    }

    # Now, open index and look for test
    $testfile_str = TestIndexParser::find_test($config, $testname);

    # Check if we found the file. If not, update the index (if not up to date).
    if ($testfile_str eq "" || !-e $testsdir.'/'.$testfile_str) { # It will remain unset if we didn't find it. Also trigger if it's indexed but the test file doesn't exist.
        if ($index_up2date) {
            verify::tdie("The test ".$config."::".$testname." could not be found!\n");
        }
        else {
            # Index may not be up to date, so update the index now and then search again!
            verify::log_status("Test not found in index. Maybe the index isn't up to date?\n");
            my ($added_count, $removed_count) = TestIndexParser::update_index($testsdir);
            $index_up2date = 1;
            verify::log_status("Updated index: added $added_count, removed $removed_count\n");
        }

        # Now that the index is updated, search for the test again...
        $testfile_str = TestIndexParser::find_test($config, $testname);

        if ($testfile_str eq "") { # Still can't find it? Then it must not exist.
            verify::tdie("The test ".$config."::".$testname." cound not be found!\n");
        }
    }
    else {
        # We found the test in the index, but now we need to make sure it actually exists where it says it does.
        my $found = 0;
        my $testfile_in;
        verify::log_status("Checking test file for test... ");
        open($testfile_in, "<$testsdir/$testfile_str") or verify::tdie("Unable to open test file!\n$!\n File: $testsdir/$testfile_str\n");
        my $line;
        do {
            $line = <$testfile_in>;
            if ($line =~ m/^\s*test:\s*$testname\s*$/) {
                my $line = "";
                do {
                    $line = <$testfile_in>;
                    $found = 1 if ($line =~ m/^\s*config=$config\s*$/);
                } while ($line !~ m/^\s*endtest\s*$/ && $found == 0);
            }
        } while($found == 0 && !eof($testfile_in));
        close($testfile_in);

        # Couldn't find the test where the index specified! Reindex and look again.
        if ($found == 0) {
            verify::log_status("Not found!\n");
            if ($index_up2date == 0) {
                my ($added_count, $removed_count) = TestIndexParser::update_index($testsdir);
                $index_up2date = 1;
                verify::log_status("Updated index: added $added_count, removed $removed_count\n");

                $testfile_str = TestIndexParser::find_test($config, $testname);
                if ($testfile_str eq "") { # Still not found? It doesn't exist.
                    verify::tdie("The test ".$config."::".$testname." could not be found!\n");
                }
            }
        }
        else {
            verify::log_status("Found it!\n");
        }
    }

    return $testfile_str;
}

### prune_comments() ###
# Prunes comments from a string.
# Parameters:
#   - A string to prune
# Returns:
#   - The pruned string
###
sub TestIndexParser::prune_comments($) {
    my $curr = $_[0];
    if ($curr ne "") {
        if ($curr =~ m/(?<=\\)#.*/) {
            $curr =~ s/\\(#.*)/$1/g;  # Not a comment, just remove backslash escaping
        } else {
            $curr =~ s/(?<!\\)#.*//g;   # remove comments from test file
        }
    }
    return $curr;
                                    }

### quick_parse_file() ###
# Does a minimal parse operation on a test file, only extracing test name, configuration, and description.
# Parameters:
#   - Filename (with path) of the test file to parse.
# Returns:
#   - Reference to an array of {name,config,description} hashes.
###
sub TestIndexParser::quick_parse_file($) {
    my ($testfile) = @_;
    my @test_list = ();

    my $file_in;
    open($file_in, "<$testfile") or return ();
    while (<$file_in>) {
        chomp;
        $_ = TestIndexParser::prune_comments($_);
        if (!/^\s*$/) {
            if (/^\s*test:\s*(\w+)\s*$/) {
                my %test_info;
                $test_info{'name'} = $1;
                my $curr;
                do {
                    $curr = <$file_in>;
                    chomp $curr;
                    $curr = TestIndexParser::prune_comments($curr);
                    
                    # Token check
                    if ($curr !~ m/^\s*$/) {
                        if ($curr =~ m/^\s*config=(\w*)\s*$/) {
                            $test_info{'config'} = $1;
                        }
                        elsif ($curr =~ m/^\s*description=(.*)\s*$/) {
                            $test_info{'description'} = $1;
                        }
                        elsif ($curr =~ m/^\s*test:\s*\w+\s*$/) {
                            verify::tdie("Found 'test:' before end of current test block!\n");
                        }
                    }
                } while ($curr !~ m/^\s*endtest\s*$/);

                push(@test_list, \%test_info);
            }
            else {
                verify::tdie("Malformed text in test definition file! Line: ".$file_in->input_line_number()."\n File: ".$testfile."\n ".$_."\n");
            }
        }
    }

    close($file_in);

    return @test_list;
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
sub TestIndexParser::parse_test_file($$$;$) {
    my $test = {"name" => "",          # Required: Identifies the test
                "description" => "",   # Required: Describes the test
                "config" => "",        # Required: Testbench config associated with the test
                "build.args" => "",    # These are custom parameters passed directly to the build tool
                "run.args" => "",      # These are custom parameters passed directly to the run tool
                "params" => "",        # This is the list of test parameters passed in the file and/or on the command-line as comma-separated values
                "define" => {},        # Used to define custom parameters for both build and run steps
                "build.define" => {},  # Same as above, but only build step
                "run.define" => {}};   # Same as above, but only run step

    my $required_flags = 0;

    my $testfile = $testsdir.'/'.$_[0];
    my $config = $_[1];
    my $name = $_[2];
    my @testparams = @{$_[3]} if (@_ > 3);

    open(TEST, "<", $testfile) or verify::tdie("Unable to open test file!\n$!\n File: $testfile\n");
    verify::log_status("Parsing test file: ".$testfile."\n");

    my $curr;
    while ($curr = <TEST>) {
        chomp $curr;
        $curr = TestIndexParser::prune_comments($curr);
        
        if ($curr !~ m/^\s*$/) {
            if ($curr =~ m/^\s*test:\s*($name)\s*$/) {
                $test->{"name"} = $1;
                $required_flags |= 1;
                do {
                    $curr = <TEST>;
                    chomp $curr;
                    $curr = TestIndexParser::prune_comments($curr);

                    if ($curr !~ m/^\s*$/) {
                        my ($key, $value) = ('', '');

                        if ($curr =~ m/^\s*define\s+(\w+\s+)?\w+=.*\s*$/) {   # Handle parsing for 'define' custom parameters...
                            if ($curr =~ m/^\s*define\s+(\w+)=(.+)\s*$/) {
                                $test->{"define"}->{$1} = $2;
                            }
                            elsif ($curr =~ m/^\s*define\s+build\s+(\w+)=(.+)\s*$/) {
                                $test->{"build.define"}->{$1} = $2;
                            }
                            elsif ($curr =~ m/^\s*define\s+run\s+(\w+)=(.+)\s*$/) {
                                $test->{"run.define"}->{$1} = $2;
                            }
                            else {
                                $curr =~ m/^\s*define\s+(\w+)\s+\w+=.*\s*$/;
                                verify::tdie("Unexpected argument to define in test definition file! Line: ".TEST->input_line_number()."\n File: ".$testfile."\n Argument: ".$1."\n");
                            }
                        }
                        elsif ($curr =~ m/\+=/) {      # Handle parsing for other test data (append)
                            ($key, $value) = split(/\+=/, $curr);
                            $key =~ s/\s//g;
                            if (exists $test->{lc($key)} && $key ne "name") {
                                $test->{lc($key)} = $test->{$key}.' '.$value;
                                if ($key eq "name") {
                                    $required_flags |= 0x1;
                                } elsif ($key eq "description") {
                                    $required_flags |= 0x2;
                                } elsif ($key eq "config") {
                                    $required_flags |= 0x4;
                                }
                            }
                            else {
                                verify::tdie("Malformed key in test definition file! Line: ".TEST->input_line_number()."\n File: ".$testfile."\n Key: ".lc($key)."\n");
                            }
                        }
                        elsif ($curr =~ m/=/) {    # Handle parsing for other test data (assign)
                            ($key, $value) = ($`, $'); #'); # Doing this to prevent emacs from misinterpreting the $' variable, and screwing up font lock mode and tabbing.
                            $key =~ s/\s//g;
                            if (exists $test->{lc($key)} && $key ne "name") {
                                $test->{lc($key)} = $value;
                                if ($key eq "name") {
                                    $required_flags |= 0x1;
                                } elsif ($key eq "description") {
                                    $required_flags |= 0x2;
                                } elsif ($key eq "config") {
                                    $required_flags |= 0x4;
                                }
                            }
                            else {
                                verify::tdie("Malformed key in test definition file! Line: ".TEST->input_line_number()."\n File: ".$testfile."\n Key: ".lc($key)."\n");
                            }
                        }
                        elsif ($curr !~ m/^\s*endtest\s*$/) {
                            verify::tdie("Malformed text in test definition file! Line: ".TEST->input_line_number()."\n File: ".$testfile."\n".$curr."\n");
                        }
                    }
                } while ($curr !~ m/^\s*endtest\s*$/);
            }
        }
    }
    
    # Check for required fields
    if ($required_flags != 0x7) {
        my $msg = "";
        $msg = "$msg Required field 'name' was not found.\n" if !($required_flags & 0x1);
        $msg = "$msg Required field 'description' was not found.\n" if !($required_flags & 0x2);
        $msg = "$msg Required field 'config' was not found.\n" if !($required_flags & 0x4);
        verify::tdie("One or more required fields were not found in the test file!\n$msg");
    }

    # Handle test parameters (custom, built-in, and command-line)
    if (@testparams) {
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
                # Substitute $$ in param value for argument (or empty string, if it expected one but didn't get one). (Can avoid substitution by using \$$.)
                $param_for_test =~ s/(?<!\\)\$\$/$pkey/;
                
                $test->{'build.args'} = $test->{'build.args'}.' '.$param_for_test;
                $test->{'run.args'} = $test->{'run.args'}.' '.$param_for_test;
            }
            elsif (exists $test->{'build.define'}->{$pname}) {
                my $param_for_test = $test->{'build.define'}->{$pname};
                # Substitute $$ in param value for argument (or empty string, if it expected one but didn't get one). (Can avoid substitution by using \$$.)
                $param_for_test =~ s/(?<!\\)\$\$/$pkey/;
                
                $test->{'build.args'} = $test->{'build.args'}.' '.$param_for_test;
            }
            elsif (exists $test->{'run.define'}->{$pname}) {
                my $param_for_test = $test->{'run.define'}->{$pname};
                # Substitute $$ in param value for argument (or empty string, if it expected one but didn't get one). (Can avoid substitution by using \$$.)
                $param_for_test =~ s/(?<!\\)\$\$/$pkey/;
                
                $test->{'run.args'} = $test->{'run.args'}.' '.$param_for_test;
            }
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
sub TestIndexParser::list_tests() {
    my $found_tests = 0;
    my $callback = sub {
        my @curr_tests = TestIndexParser::quick_parse_file($testsdir.'/'.$_[0]);
        if (@curr_tests) {
            foreach my $curr_test (@curr_tests) {
                verify::tlog(0, " ".$curr_test->{'config'}."::".$curr_test->{'name'}." - ".$curr_test->{'description'}."\n");
                $found_tests ++;
            }
        }
        else {
            verify::tdie("Unable to open test file!\n$!\n File: $testsdir/$_[0]\n");
        }
    };

    verify::log_status("Finding all test files...\n");
    verify::tlog(0, "Listing all available tests:\n");
    verify::tlog(0, "----------------------------\n");
    TestIndexParser::recursive_scan($testsdir, $callback);
    verify::log_status("Found $found_tests tests.\n");
    verify::tlog(0, "End test list.\n");
}

1;
