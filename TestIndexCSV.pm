# TestIndexCSV.pm
# Indexes tests and parses test files. Uses TestIndex module for test parsing.
# Benjamin Richards, (c) 2013

use strict;
use DBI;
use TestIndex;

package verify::TestIndexCSV;

# Function prototypes
sub TestIndexCSV::set_testsdir( $ );
sub TestIndexCSV::find_test( $$ );
sub TestIndexCSV::get_test_file( $$ );
sub TestIndexCSV::get_test( $$$;$ );
sub TestIndexCSV::list_tests();
sub update_index( $ );

# Index API
sub TestIndexCSV::open_index( ;$ );
sub TestIndexCSV::close_index( ;$ );
sub TestIndexCSV::create_index();
sub TestIndexCSV::query_index( $;@ );
sub TestIndexCSV::query_index_all( $;@ );
sub TestIndexCSV::query_index_fast( $ );
sub TestIndexCSV::next_id();

my $dbh;

### next_id() ###
# Calculates the next available ID number from index database. For use in SQL statements.
# Returns:
#   - The ID number
###
sub TestIndexCSV::next_id() {
    my ($self, $sth, @params);
    my $dbh = $sth->{Database};
    my @row = TestIndexCSV::query_index("SELECT COUNT(id) + 1 FROM tests");
    return $row[0];
}

### create_index() ###
# Creates a new index file
#   - Handle to index
###
sub TestIndexCSV::create_index() {
    $dbh = TestIndexCSV::open_index(0);
    my $success = TestIndexCSV::query_index_fast("CREATE TABLE tests ( id INT, name TEXT, config TEXT, file TEXT, line_number INT )");

    if ($success > 0) {
        verify::tdie("Error creating index!\n".DBI->errstr."\n");
    }

    return $dbh;
}

### open_index() ###
# Opens the index for querying
# Parameters:
#   - 0 to disable message logging. (optional; enabled is default)
# Returns:
#   - Handle to index
###
sub TestIndexCSV::open_index( ;$ ) {
    verify::log_status("Opening index.\n") unless (defined $_[0] && $_[0] == 0);
    my @columns = qw(config name file line_number);
    $dbh = DBI->connect("dbi:CSV:f_dir=$ENV{PRJ_HOME}/.verify");
    $dbh->{RaiseError} = 1;
    return $dbh;
}

### close_index() ###
# Closes a previously opened index handle.
# Parameters:
#   - 0 to enable message logging. (optional; enabled is default)
###
sub TestIndexCSV::close_index( ;$ ) {
    verify::log_status("Closing index.\n") unless (defined $_[0] && $_[0] == 0);
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
sub TestIndexCSV::query_index( $;@ ) {
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
sub TestIndexCSV::query_index_fast( $ ) {
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
sub TestIndexCSV::query_index_all( $;@ ) {
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
sub TestIndexCSV::set_testsdir( $ ) {
    TestIndex::set_testsdir($_[0]);
    $testsdir = "$_[0]";
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

    verify::log_status("Updating index...\n");

    # Do a check for exist and remove those that don't exist anymore, storing those that do...
    my $currfiles_arr = TestIndexCSV::query_index_all("SELECT DISTINCT file FROM tests");
    foreach my $c (@{$currfiles_arr}) {
        my @c_arr = @{$c};
        if (!-e $testsdir.'/'.$c_arr[0]) {
            TestIndexCSV::query_index_fast("DELETE FROM tests WHERE file=".$c_arr[0]) or verify::tdie("Error deleting test from index!\n".DBI->errstr."\n");
        }
    }
    

    # Now, the index contains only previously indexed tests that still exist.
    $currfiles_arr = TestIndexCSV::query_index_all("SELECT DISTINCT file FROM tests");
    my %currfiles;

    # Scan existing files for tests that aren't yet indexed...
    foreach my $currfile (@{$currfiles_arr}) {
        my @currfile_arr = @{$currfile};
        $currfiles{$currfile_arr[0]} = 1; # In the meantime, store off our files into a hash for reference later, if we need it.
        my @curr_tests = TestIndex::quick_parse_file($testsdir.'/'.$currfile_arr[0]);
        if (@curr_tests) {
            foreach my $test (@curr_tests) {
                if (@{TestIndexCSV::query_index_all("SELECT * WHERE config=? AND name=?", $test->{'config'}, $test->{'name'})} == 0) {
                    # Didn't index this test yet! Add it to our index.
                    TestIndexCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", TestIndexCSV::next_id(),  $test->{'name'}, $test->{'config'}, $currfile, $test->{'line'});
                    $added_count++;
                }
            }
        }
        else {
            # Something went horribly wrong. The file should have been already verified to exist.
            verify::tdie("Unable to open test file while indexing tests!\n$!\n File: $testsdir/$currfile\n");
        }
    }

    # Now, the index contains all tests that exist in previously indexed test files.
    # Scan the file system for any test files we haven't yet indexed...
    my $index_count = 0;
    my $callback = sub {
        my $currfile = $_[0];

        # Checks if current found file is already indexed. If not, add its tests.
        my @results = TestIndexCSV::query_index_all("SELECT * FROM tests WHERE file='".$currfile."'");
        if (@results == 0) {
            my @tests = TestIndex::quick_parse_file($testsdir.'/'.$currfile);
            if (@tests) {
                foreach my $test (@tests) {
                    TestIndexCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", TestIndexCSV::next_id(), $test->{'name'}, $test->{'config'}, $currfile, $test->{'line'});
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
    verify::log_status("Done!\n");

    return ($added_count, $removed_count);
}

### find_test() ###
# Searches the index for the test specified.
# Parameters:
#   - Config for the test
#   - Name of the test
# Returns:
#   - If found, a list containing: filename of the test file, line number within file
###
sub TestIndexCSV::find_test($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    verify::log_status("Looking up test file in index... ");
    my @results = TestIndexCSV::query_index("SELECT file, line_number FROM tests WHERE NAME=? AND CONFIG=?", $testname, $config);
    if (@results > 0) { # We found it!
        verify::log_status("Found. [$results[0]:$results[1]]\n");
        return @results;
    }
    else {
        verify::log_status("Not found!\n");
    }
}

### get_test_file() ###
# Finds the path to the test file in which the provided config::test pair is defined.
# Parameters:
#   - Configuration string for the test
#   - Name of the test
# Returns:
#   - Relative path and filename (under $testsdir) to the test file.
###
sub TestIndexCSV::get_test_file($$) {
    my ($config, $testname) = @_;
    my $testfile_str = "";
    my $line_number = 0;
    my $index_up2date = 0;

    # First, check if index exists
    if (!-e $ENV{'PRJ_HOME'}.'/.verify/tests') {
        # Index doesn't exist: build it!
        verify::log_status("Index not found! I'll build the index right now.\n");
        
        my $indexed_count = 0;
        mkdir "$ENV{PRJ_HOME}/.verify" unless (-d "$ENV{PRJ_HOME}/.verify");
        
        TestIndexCSV::create_index();
        my $callback = sub {
            # Parameters: filename
            my @curr_tests = TestIndex::quick_parse_file($testsdir.'/'.$_[0]);
            if (@curr_tests) {
                foreach my $curr_test (@curr_tests) {
                    TestIndexCSV::query_index("INSERT INTO tests VALUES (?, ?, ?, ?, ?)", $indexed_count, $curr_test->{'name'}, $curr_test->{'config'}, $_[0], $curr_test->{'line'});
                    $indexed_count ++;
                }
            }
            else {
                verify::tdie("Unable to open test file when creating index!\n$!\n File: $testsdir/$_[0]\n");
            }
        };
        
        TestIndex::recursive_scan($testsdir, $callback);
        TestIndexCSV::close_index(0);
        verify::log_status("Indexed $indexed_count tests.\n");

        $index_up2date = 1;
    }


    # Now, open index and look for test
    TestIndexCSV::open_index();
    ($testfile_str, $line_number) = TestIndexCSV::find_test($config, $testname);

    # Check if we found the file. If not, update the index (if not up to date).
    if ($testfile_str eq "" || !-e $testsdir.'/'.$testfile_str) { # It will remain unset if we didn't find it. Also trigger if it's indexed but the test file doesn't exist.
        if ($index_up2date) {
            verify::tdie("The test ".$config."::".$testname." could not be found!\n");
        }
        else {
            # Index may not be up to date, so update the index now and then search again!
            verify::log_status("Test not found in index. Maybe the index isn't up to date?\n");
            my ($added_count, $removed_count) = update_index($testsdir);
            $index_up2date = 1;
            verify::log_status("Updated index: added $added_count, removed $removed_count\n");
        }

        # Now that the index is updated, search for the test again...
        ($testfile_str, $line_number) = TestIndexCSV::find_test($config, $testname);

        if ($testfile_str eq "") { # Still can't find it? Then it must not exist.
            verify::tdie("The test ".$config."::".$testname." could not be found!\n");
        }
    }
    else {
        # We found the test in the index, but now we need to make sure it actually exists where it says it does.
        verify::log_status("Checking indexed file location for test...\n");
        my $found = TestIndex::test_exists($testfile_str, $testname, $config, $line_number);

        # Couldn't find the test where the index specified! Reindex and look again.
        if ($found == 0) {
            verify::log_status("Not found!\n");
            if ($index_up2date == 0) {
                my ($added_count, $removed_count) = update_index($testsdir);
                $index_up2date = 1;
                verify::log_status("Updated index: added $added_count, removed $removed_count\n");

                ($testfile_str, $line_number) = TestIndexCSV::find_test($config, $testname);
                if ($testfile_str eq "") { # Still not found? It doesn't exist.
                    verify::tdie("The test ".$config."::".$testname." could not be found!\n");
                }
            }
        }
        else {
            verify::log_status("Test exists.\n");
        }
    }

    TestIndexCSV::close_index();

    return $testfile_str;
}

### get_test() ###
# Parses test arguments specified in *.test files.
# Parameters:
#   - Filename (with relative path) of the test file to parse.
#   - Configuration of the test to load
#   - Name of the test to load
#   - Parameters passed on command-line (optional)
# Returns:
#   - A reference to the test information stored in a relational array in memory
###
sub TestIndexCSV::get_test( $$$;$ ) {
    my ($filename, $config, $name, $params) = @_;
    return TestIndex::get_test($filename, $config, $name, $params);
}

### list_tests() ###
# Does a recursive search under the tests root directory and displays each tests' config, name, and description in a list.
# Note: This function does not use the index file.
###
sub TestIndexCSV::list_tests() {
    TestIndex::list_tests();
}

1;
