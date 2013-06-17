# TestParser.pm
# Perl module used by Verify tool to handle test file parsing
# Written by Benjamin Richards, (c) 2012

use strict;

package verify::TestParser;

# Function prototypes
sub TestParser::set_testsdir($);
sub TestParser::get_test_file($$);
sub TestParser::parse_test_file($$$;$);
sub TestParser::list_tests();

# Root directory of where the test files live
my $testsdir = "";

# Allow us to set $testsdir
sub TestParser::set_testsdir($) {
    $testsdir = $_[0];
}

# Gets two parameters: config and test name, and returns the file path containing the test definition
sub TestParser::get_test_file($$) {
    my ($config, $testname) = @_;
    return $config.'/'.$testname.'.test';
}

### parse_test_file() ###
# Parses test arguments specified in *.test files.
# Parameters:
#   - Filename (with path) of the test file to parse.
#   - Configuration of the test to parse.
#   - Name of the test to parse.
#   - Any parameters to the test passed on command-line to include. (optional)
# Returns:
#   - A reference to the test information stored in a relational array in memory
###
sub TestParser::parse_test_file($;$) {
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

    my $testfile = $_[0];
    my $config = $_[1];
    my $name = $_[2];
    my @testparams = @{$_[3]} if (@_ > 3);

    open(TEST, "<", $testfile) or verify::tdie("Unable to open test file!\n $!\n File: ".$testfile."\n");
    verify::log_status("Parsing test file: ".$testfile."\n");

    my $curr;
    while ($curr = <TEST>) {
        chomp $curr;

        # Parse out any comments that might be on the line
        if ($curr =~ m/(?<=\\)#.*/) {
            $curr =~ s/\\(#.*)/$1/g;  # Not a comment, just remove backslash escaping
        } else {
            $curr =~ s/(?<!\\)#.*//g;   # remove comments from test file
        }
        
        if ($curr ne "") {
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
                    verify::tdie("Unexpected argument to define in test definition file, line ".TEST->input_line_number()."\n File: ".$testfile."\n Argument: ".$1."\n");
                }
            }
            elsif ($curr =~ m/\+=/) {      # Handle parsing for other test data (append)
                ($key, $value) = split(/\+=/, $curr);
                $key =~ s/\s//g;
                if (exists $test->{lc($key)}) {
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
                    verify::tdie("Malformed key in test definition file, line ".TEST->input_line_number()."\n File: ".$testfile."\n Key: ".lc($key)."\n");
                }
            }
            elsif ($curr =~ m/=/) {    # Handle parsing for other test data (assign)
                ($key, $value) = split "=", $curr;
                $key =~ s/\s//g;
                if (exists $test->{lc($key)}) {
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
                    verify::tdie("Malformed key in test definition file, line ".TEST->input_line_number()."\n File: ".$testfile."\n Key: ".lc($key)."\n");
                }
            }
            else {
                verify::tdie("Malformed text in test definition file, line ".TEST->input_line_number()."\n File: ".$testfile."\n".$curr."\n");
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
            my ($pname, $pkey) = split(/=/, $p);
            
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
# When the tool is invoked with -p or --print, this function is called to search out all *.test files and print a list of tests available to run.
# This function exits the script when completed.
###
sub TestParser::list_tests() {
    verify::log_status("Finding all test files...\n");
    verify::tlog(0, "Listing all available tests:\n");
    verify::tlog(0, "----------------------------\n");

    my @dirs = grep{ -d } glob "$testsdir/*";
    foreach my $curr_dir (@dirs) {
        foreach my $curr_file (<$curr_dir/*.test>) {
            my $curr_test = TestParser::parse_test_file($curr_file);
            verify::tlog(0, " ".$curr_test->{'config'}."::".$curr_test->{'name'}." - ".$curr_test->{'description'}."\n");
        }
        
        verify::tlog(0, "\n");
    }
    
    verify::log_status("Found no more test files.\n\n");
    verify::tlog(0, "End test list.\n");
}

1;
