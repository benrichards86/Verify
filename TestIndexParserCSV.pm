# TestIndexParserCSV.pm
# Indexes tests and parses test files. Supports multiple tests per file. Uses a CSV file format and SQL queries.
# Benjamin Richards, (c) 2013

use strict;
use DBI;

package verify::TestIndexParserCSV;

# Function prototypes
sub TestIndexParserCSV::set_testsdir( $ );
sub TestIndexParserCSV::recursive_scan( $$ );
sub TestIndexParserCSV::update_index( $ );
sub TestIndexParserCSV::prune_comments( $ );
sub TestIndexParserCSV::find_test( $$ );
sub TestIndexParserCSV::get_test_file( $$ );
sub TestIndexParserCSV::quick_parse_file( $ );
sub TestIndexParserCSV::parse_test_file( $$$;$ );
sub TestIndexParserCSV::list_tests();

# Index API
sub TestIndexParserCSV::open_index();
sub TestIndexParserCSV::close_index();
sub TestIndexParserCSV::create_index();
sub TestIndexParserCSV::query_index( $;@ );
sub TestIndexParserCSV::query_index_all( $;@ );
sub TestIndexParserCSV::query_index_fast( $ );
sub TestIndexParserCSV::next_id();

my $dbh;

### next_id() ###
# Calculates the next available ID number from index database. For use in SQL statements.
# Returns:
#   - The ID number
###
sub TestIndexParserCSV::next_id() {
    my ($self, $sth, @params);
    my $dbh = $sth->{Database};
    my @row = TestIndexParserCSV::query_index("SELECT COUNT(id) + 1 FROM tests");
    return $row[0];
}

### create_index() ###
# Creates a new index file
#   - Handle to index
###
sub TestIndexParserCSV::create_index() {
    $dbh = TestIndexParserCSV::open_index();
    my $success = TestIndexParserCSV::query_index_fast("CREATE TABLE tests ( id INT, name TEXT, config TEXT, file TEXT, line_number INT )");

    if ($success > 0) {
        verify::tdie("Error creating index!\n".DBI->errstr."\n");
    }

    return $dbh;
}

### open_index() ###
# Opens the index for querying
# Returns:
#   - Handle to index
###
sub TestIndexParserCSV::open_index() {
    verify::log_status("Opening index...\n");
    my @columns = qw(config name file line_number);
    $dbh = DBI->connect("dbi:CSV:f_dir=$ENV{PRJ_HOME}/.verify");
    $dbh->{RaiseError} = 1;
    return $dbh;
}

### close_index() ###
# Closes a previously opened index handle.
# Parameters:
#   - Handle to index (optional)
###
sub TestIndexParserCSV::close_index() {
    verify::log_status("Closing index.\n");
    $dbh->disconnect;
}

### query_index() ###
# Runs a SQL query against index
# Parameters:
#   - A SQL statement to execute (with any field values replaced with '?')
#   - List of field values (optional)
# Returns:
#   - Any results from query as an array of columns
###
sub TestIndexParserCSV::query_index( $;@ ) {
    my @results = ();
    my $sql = shift @_;
    #verify::log_status("Executing SQL> ".$sql."; (".join(",",@_).")\n");

    my $sth = $dbh->prepare($sql);
    $sth->execute(@_);
    @results = $sth->fetchrow_array if $sth->{NUM_OF_FIELDS};
    $sth->finish();
    return @results;
}

### query_index_fast() ###
# Runs a SQL query against index that doesn't return a set of rows. Returns success/fail.
# Parameters:
#   - A SQL statement to execute
# Returns:
#   - 0 for success, non-zero for failure.
###
sub TestIndexParserCSV::query_index_fast( $ ) {
    my $sql = shift @_;
    my @results = ();

    #verify::log_status("Executing SQL> ".$sql.";\n");
    return $dbh->do($sql);
}

### query_index_all() ###
# Same as query_index(), but returns an array reference for all results, instead of just the first row.
# Parameters:
#   - SQL statement (with any field values replaced with '?')
#   - List of field values (optional)
# Returns:
#   - Reference to an array of rows returned from the SQL query
###
sub TestIndexParserCSV::query_index_all( $;@ ) {
    my $sql = shift @_;
    #verify::log_status("Executing SQL> ".$sql."; (".join(",",@_).")\n");
    my $sth = $dbh->prepare($sql);
    $sth->execute(@_);

    my $ary = $sth->fetchall_arrayref();

    #verify::log_status("SQL results> Returned ".@{$ary}." rows.\n");
    return $ary;
}

# Root directory where test files will live under
my $testsdir = "";

# To set testsdir
sub TestIndexParserCSV::set_testsdir( $ ) {
    $testsdir = $_[0];
}

### recursive_scan() ###
# Recursively scans from the root directory for *.test files, and calls a handler function on each file.
# Parameters:
#   - Current directory to search under
#   - Alias to anonymous function to call on each file found
###
sub TestIndexParserCSV::recursive_scan($$) {
    my ($root_dir, $handler) = @_;

    # Index any files in subdirectories
    my @dirs = grep{ -d } glob $root_dir.'/*';
    foreach my $curr_dir (@dirs) {
        TestIndexParserCSV::recursive_scan($curr_dir, $handler);
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
sub TestIndexParserCSV::update_index($) {
    my ($added_count, $removed_count) = (0, 0);
    my ($root_dir) = @_;

    verify::log_status("Updating index...\n");

    # Do a check for exist and remove those that don't exist anymore, storing those that do...
    TestIndexParserCSV::open_index();
    my $currfiles_arr = TestIndexParserCSV::query_index_all("SELECT DISTINCT file FROM tests");
    foreach my $c (@{$currfiles_arr}) {
        my @c_arr = @{$c};
        if (!-e $testsdir.'/'.$c_arr[0]) {
            TestIndexParserCSV::query_index_fast("DELETE FROM tests WHERE file=".$c_arr[0]) or verify::tdie("Error deleting test from index!\n".DBI->errstr."\n");
        }
    }
    

    # Now, the index contains only previously indexed tests that still exist.
    $currfiles_arr = TestIndexParserCSV::query_index_all("SELECT DISTINCT file FROM tests");
    my %currfiles;

    # Scan existing files for tests that aren't yet indexed...
    foreach my $currfile (@{$currfiles_arr}) {
        my @currfile_arr = @{$currfile};
        $currfiles{$currfile_arr[0]} = 1; # In the meantime, store off our files into a hash for reference later, if we need it.
        my @curr_tests = TestIndexParserCSV::quick_parse_file($testsdir.'/'.$currfile_arr[0]);
        if (@curr_tests) {
            foreach my $test (@curr_tests) {
                if (@{TestIndexParserCSV::query_index_all("SELECT * WHERE config=? AND name=?", $test->{'config'}, $test->{'name'})} == 0) {
                    # Didn't index this test yet! Add it to our index.
                    TestIndexParserCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", TestIndexParserCSV::next_id(),  $test->{'name'}, $test->{'config'}, $currfile, $test->{'line'});
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
        my @results = TestIndexParserCSV::query_index_all("SELECT * FROM tests WHERE file='".$currfile."'");
        if (@results == 0) {
            my @tests = TestIndexParserCSV::quick_parse_file($testsdir.'/'.$currfile);
            if (@tests) {
                foreach my $test (@tests) {
                    TestIndexParserCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", TestIndexParserCSV::next_id(), $test->{'name'}, $test->{'config'}, $currfile, $test->{'line'});
                    $added_count ++;
                }
            }
            else {
                verify::tdie("Error reading test file!\n$!\n File: $testsdir/$currfile\n");
            }
        }
    };

    TestIndexParserCSV::recursive_scan($testsdir, $callback);
    
    # Index is updated!
    TestIndexParserCSV::close_index();
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
sub TestIndexParserCSV::find_test($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    verify::log_status("Searching index for test...\n");
    TestIndexParserCSV::open_index();
    my @results = TestIndexParserCSV::query_index("SELECT file FROM tests WHERE NAME=? AND CONFIG=?", $testname, $config);
    if (@results > 0) { # We found it!
        verify::log_status("Found it!\n");
        $testfile_str = $results[0];
    }
    else {
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
sub TestIndexParserCSV::get_test_file($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    my $index_up2date = 0;

    # First, check if index exists
    if (!-e $ENV{'PRJ_HOME'}.'/.verify/tests') {
        # Index doesn't exist: build it!
        verify::log_status("Index not found! Doing initial build...\n");
        
        my $indexed_count = 0;
        mkdir "$ENV{PRJ_HOME}/.verify" unless (-d "$ENV{PRJ_HOME}/.verify");
        
        TestIndexParserCSV::create_index();
        my $callback = sub {
            # Parameters: filename
            my @curr_tests = TestIndexParserCSV::quick_parse_file($testsdir.'/'.$_[0]);
            if (@curr_tests) {
                foreach my $curr_test (@curr_tests) {
                    TestIndexParserCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", $indexed_count, $curr_test->{'name'}, $curr_test->{'config'}, $_[0], $curr_test->{'line'});
                    $indexed_count ++;
                }
            }
            else {
                verify::tdie("Unable to open test file!\n$!\n File: $testsdir/$_[0]\n");
            }
        };
        
        TestIndexParserCSV::recursive_scan($testsdir, $callback);
        verify::log_status("Indexed $indexed_count tests.\n");
        TestIndexParserCSV::close_index();

        $index_up2date = 1;
    }

    # Now, open index and look for test
    $testfile_str = TestIndexParserCSV::find_test($config, $testname);

    # Check if we found the file. If not, update the index (if not up to date).
    if ($testfile_str eq "" || !-e $testsdir.'/'.$testfile_str) { # It will remain unset if we didn't find it. Also trigger if it's indexed but the test file doesn't exist.
        if ($index_up2date) {
            verify::tdie("The test ".$config."::".$testname." could not be found!\n");
        }
        else {
            # Index may not be up to date, so update the index now and then search again!
            verify::log_status("Test not found in index. Maybe the index isn't up to date?\n");
            my ($added_count, $removed_count) = TestIndexParserCSV::update_index($testsdir);
            $index_up2date = 1;
            verify::log_status("Updated index: added $added_count, removed $removed_count\n");
        }

        # Now that the index is updated, search for the test again...
        $testfile_str = TestIndexParserCSV::find_test($config, $testname);

        if ($testfile_str eq "") { # Still can't find it? Then it must not exist.
            verify::tdie("The test ".$config."::".$testname." cound not be found!\n");
        }
    }
    else {
        # We found the test in the index, but now we need to make sure it actually exists where it says it does.
        my $found = 0;
        my $testfile_in;
        verify::log_status("Checking test file for test...\n");
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
                my ($added_count, $removed_count) = TestIndexParserCSV::update_index($testsdir);
                $index_up2date = 1;
                verify::log_status("Updated index: added $added_count, removed $removed_count\n");

                $testfile_str = TestIndexParserCSV::find_test($config, $testname);
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
sub TestIndexParserCSV::prune_comments($) {
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
sub TestIndexParserCSV::quick_parse_file($) {
    my ($testfile) = @_;
    my @test_list = ();

    my $file_in;
    open($file_in, "<$testfile") or return ();
    while (<$file_in>) {
        chomp;
        $_ = TestIndexParserCSV::prune_comments($_);
        if (!/^\s*$/) {
            if (/^\s*test:\s*(\w+)\s*$/) {
                my %test_info;
                $test_info{'name'} = $1;
                $test_info{'line'} = $file_in->input_line_number();
                my $curr;
                do {
                    $curr = <$file_in>;
                    chomp $curr;
                    $curr = TestIndexParserCSV::prune_comments($curr);
                    
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
sub TestIndexParserCSV::parse_test_file($$$;$) {
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
        $curr = TestIndexParserCSV::prune_comments($curr);
        
        if ($curr !~ m/^\s*$/) {
            if ($curr =~ m/^\s*test:\s*($name)\s*$/) {
                $test->{"name"} = $1;
                $required_flags |= 1;
                do {
                    $curr = <TEST>;
                    chomp $curr;
                    $curr = TestIndexParserCSV::prune_comments($curr);

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
sub TestIndexParserCSV::list_tests() {
    my $found_tests = 0;
    my $callback = sub {
        my @curr_tests = TestIndexParserCSV::quick_parse_file($testsdir.'/'.$_[0]);
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
    TestIndexParserCSV::recursive_scan($testsdir, $callback);
    verify::log_status("Found $found_tests tests.\n");
    verify::tlog(0, "End test list.\n");
}

1;
