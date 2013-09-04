#!/usr/bin/perl -w

## verify.pl
## A simple verification tool to manage the definition, building, and running of tests in a verification environment.
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
use Cwd;
use IO::Handle;
use Thread::Semaphore;
use POSIX ":sys_wait_h";
use Getopt::Long qw(:config posix_default no_ignore_case bundling require_order);
use Pod::Usage;
use Pod::Html;
use FindBin;
use lib "$FindBin::Bin";

package verify;

use File::Copy;

BEGIN {
    # Pull in our test file parser module and alias it.
    # I would do this at run-time, allowing you to specify the module in verify.ini, but Perl doesn't allow package
    #  aliasing at run-time, making it impossible (or at least incredibly difficult) to do what I want to do. I'll
    #  settle with this for now.
    require TestIndex;
    *Index:: = *TestIndex::;
}


################################################################################
## Private variables
my $initialized = 0;
my $logfile;
my $errfile;
my $statusfile;
my $sf_semaphore;

my $root_dir;
my $test_dir;
my $install_dir;


my $email_list = "";
my $email_subject = "Test completed";

my @tests = ();  # Array of tests

my $me;

# For parallel mode
my %children;
my $is_child;

# Report table
my $report_file;
my $report_semaphore;

# Disable warnings for PRJ_HOME if not initialized
no warnings 'uninitialized';

# Options hash - configurations info for script
my %options = ("quiet" => 0,
               "build" => 1,
               "run" => 1,
               "debug" => 0,
               "interactive" => 0,
               "email" => 0,
               "null" => 0,
               "report" => 0,
               "parallel" => 0,
               "libsdir" => $ENV{'PRJ_HOME'}."/verification/scripts");

################################################################################
## Global variables
$verify::debug = 0;
$verify::interactive = 0;
$verify::logfile = "verify.log";
$verify::build_dir = "";
$verify::run_dir = "";
$verify::testsdir = $ENV{'PRJ_HOME'}."/verification/tests";

$verify::VERSION = "Verify v2.3.1";
$verify::AUTHOR = "Benjamin D. Richards";
$verify::COPYRIGHT = "Verify comes with ABSOLUTELY NO WARRANTY. This is free software, and you are welcome to redistribute\nit under certain conditions. For details, read COPYRIGHT.\n";
$verify::REPOSITORY = "https://github.com/benrichards86/Verify";

################################################################################
## Function prototypes
sub finish_child( $ );
sub finish_logs();
sub finish( $ );
sub init();
sub init_logs();
sub log_status( $ );
sub log_report( $$ );
sub parse_tool_args();
sub run_command( $ );
sub tdie( $ );
sub tlog( $$ );
sub send_email();


################################################################################
## Function definitions

### init() ###
# Initialization setup for the script. Always is run at the very beginning.
###
sub init() {
    $root_dir = Cwd::getcwd();
    my @t = split(/\//, $0);
    $me = $t[$#t];

    $0 =~ m/.$me/;
    $install_dir = $`;

    $| = 1; # I want my pipes to be piping hot!

    # Open and read config file if present
    if (-e $ENV{'PRJ_HOME'}.'/verify.ini') {
        open(CONFIG, "<".$ENV{'PRJ_HOME'}."/verify.ini");
        while(<CONFIG>) {
            if (/testsdir=(.*)/) {
                $verify::testsdir = $ENV{'PRJ_HOME'}.'/'.$1;
            }
            elsif (/libsdir=(.*)/) {
                $options{'libsdir'} = $ENV{'PRJ_HOME'}.'/'.$1;
            }
        }
    }

    my $now = localtime(); # Get timestamp

    Index::set_testsdir($verify::testsdir);
    $sf_semaphore = Thread::Semaphore->new();

    $sf_semaphore->down();
    open($statusfile, ">", "verify_status") or die "Unable to open verify_status for write! $!";
    $statusfile->autoflush(1);
    print $statusfile $me." ".(join ' ', @ARGV)."\n";
    print $statusfile "User: ".$ENV{'USER'}."\n";
    print $statusfile "Hostname: ".$ENV{'HOSTNAME'}."\n";
    print $statusfile "Timestamp: ".$now."\n";
    print $statusfile "Working directory: ".$root_dir."\n";
    print $statusfile "Install directory: ".$install_dir."\n";
    print $statusfile "User libs directory: ".$options{'libsdir'}."\n";
    print $statusfile "Tests directory: ".$verify::testsdir."\n";
    print $statusfile "======================================================================\n";
    print $statusfile "\n";
    $sf_semaphore->up();

    my @envlist = ();
    foreach my $k (keys(%ENV)) {
        push(@envlist, $k."=".$ENV{$k});
    }
    open(ENVLOG, ">verify_status.env") or die "Unable to open verify_status.env for write! $!";
    print ENVLOG join("\n", sort @envlist)."\n" and close(ENVLOG) or die "Unable to write to verify_status.env! $!";

    parse_tool_args();

    if ($options{'report'}) {
        $report_semaphore = Thread::Semaphore->new();
        $report_semaphore->down();
        my $ret = open($report_file, ">$root_dir/report.txt");
        if (!$ret) {
            tlog(1, "Could not create report file!$!\n");
            log_status("Could not create report file!\n");
            $options{'report'} = 0;
        }
        else {
            $report_file->autoflush(1);
            my $header = "Test Results: ($now)\n--------------------------------------------------------------------------------\n";
            print $report_file $header;
            log_status("Report file created at: $root_dir/report.txt [FILEHANDLE $report_file]\n");
        }
        $report_semaphore->up();
    }

    unshift @INC, $options{'libsdir'};
    eval "require build_test";
    tdie($@) if $@;
    eval "require run_test";
    tdie($@) if $@;

    log_status("Initialization complete.\n\n");
    $initialized = 1;
}

### tdie() ###
# Use this function instead of Perl's built-in die(). It fulfills the same functionality, while also handling log cleanup.
# Parameters:
#   - Message to output on exit
###
sub tdie( $ ) {
    my ($str) = @_;
    tlog(1, $str);
    log_status("Script ended prematurely: $str");
    $email_subject = "Exited with error";
    finish(255);  # Exit the script
}

### tlog() ###
# Basic logging mechanism for the script. Use it instead of Perl's built-in print() (and related functions) for all console output.
# Parameters:
#   - Logging level. 0 => standard output, 1 => error output
###
sub tlog( $$ ) {
    my ($level, $str) = @_;

    if ($level >= 1) {
        print STDERR $str if (!$options{'quiet'});
        seek($errfile, 0, 2) and print $errfile $str if ($errfile && $errfile->opened);
    }
    elsif ($level >= 0) {
        print STDOUT $str if (!$options{'quiet'});
    }
    
    seek($logfile, 0, 2) and print $logfile $str if ($logfile && $logfile->opened);
}

### log_status() ###
# Logging mechanism for outputting script status messages to the verify_status log. It's a utility function, and shouldn't be used in user-implemented code.
# Parameters:
#   - Message to log
###
sub log_status( $ ) {
    $sf_semaphore->down();
    my ($str) = @_;

    if ($initialized == 1 && $options{'parallel'} > 0) {
        if (defined($is_child) && $is_child == 1) {
            $str = "<Child> [PID ".$$."] ".$str;
        }
        else {
            $str = "<Parent> ".$str;
        }
    }

    seek($statusfile, 0, 2) and print $statusfile $str if $statusfile;
    $sf_semaphore->up();
}


### parse_tool_args() ###
# Parses command-line options passed to the script. If modified, please update the documentation to describe the new options or changed functionality.
#  NOTE: This also will parse the list of tests to run, use that to derive what test files to open, and will call get_test() to load each test.
###
sub parse_tool_args() {
    Getopt::Long::GetOptions('quiet|q'       => \$options{'quiet'}, 
                             'verbose|v'     => \$options{'verbose'}, 
                             'build!'        => \$options{'build'}, 
                             'run!'          => \$options{'run'},
                             'debug|d'       => \$options{'debug'},
                             'interactive|i' => \$options{'interactive'},
                             'n'             => \$options{'null'},
                             'report|r'      => \$options{'report'},
                             'log|l=s'       => \$verify::logfile,
                             'email|e=s'     => sub { $options{'email'} = 1; $email_list = $_[1] },
                             'print|p'       => sub { Index::list_tests(); finish(0); },
                             'parallel|P=i'  => sub {
                                 my $n = $_[1];
                                 if ($n < 1) {
                                     # First, log error message to our log files
                                     log_status("Invalid number of parallel tests (".$n."). Number should be greater than or equal to 1.\n");
                                     die("Invalid number of parallel tests (".$n."). Number should be greater than or equal to 1.\n");
                                 }
                                 else {
                                     $options{'parallel'} = $n;
                                     $options{'quiet'} = 1;
                                 }
                             },
                             'help|h'        => sub { Pod::Usage::pod2usage(-verbose => 1, -exitval => 'NOEXIT'); finish(0); },
                             'man'           => sub { Pod::Usage::pod2usage(-verbose => 2, -exitval => 'NOEXIT'); finish(0); },
                             'man2html'      => sub { Pod::Html::pod2html("--header", "--infile=$0", "--outfile=verify.html"); finish(0); },
                             'version'       => sub { tlog(0, $verify::VERSION." developed by ".$verify::AUTHOR." [".$verify::REPOSITORY."]\n\n".$verify::COPYRIGHT."\n"); finish(0); }
        ) or Pod::Usage::pod2usage(-verbose => 0, -exitval => 'NOEXIT') and tdie("Command option parsing failed.\n");

    # Here, we can now check for required environment variables (allows us to display help without errors in a fresh install).
    if (!defined $ENV{'PRJ_HOME'}) {
        tdie("Required PRJ_HOME environment variable not set! It should point to the top of your tree.\n");
    }

    if (!-d $ENV{'PRJ_HOME'}) {
        tdie("Can't read directory at \$PRJ_HOME! It should point to the top of your tree.\n>PRJ_HOME=$ENV{PRJ_HOME}\n");
    }

    # Enforce using -d and -i together should only set -i as the options are mutually exclusive...
    $options{'debug'} = 0 if ($options{'interactive'} == 1);

    $verify::debug = 1 if $options{'debug'};
    $verify::interactive = 1 if $options{'interactive'};

    # The rest of the args in @ARGV will be config::test pairs (if any)
    my $test_id = 1;
    while (@ARGV) {
        my $curr = shift @ARGV;

        Pod::Usage::pod2usage(-verbose => 0, -exitval => 'NOEXIT') and tdie("Invalid config::testname pair: '$curr'\n") if ($curr !~ m/::/);

        my ($config, $name) = split "::", $curr;
        my $repeat = 1;

        # Check for repeats
        if ($name =~ m/(.+)\{(\d+)\}/) {
            $name = $1;
            $repeat = $2;
        }
        
        # name can have comma-separated test params (first token is test name)
        my @testparams = split ',', $name;
        my $testname = shift @testparams;
        
        # Get test file
        my $file = Index::get_test_file($config, $testname);

        if ($file ne "") {
            # Parse test file
            my $currtest = Index::get_test($file, $config, $testname, \@testparams);
            
            # Store test (as many times as indicated by $repeat)
            for (my $n = 0; $n < $repeat; $n++) {
                my %currtest_cpy = %$currtest;
                $currtest_cpy{'id'} = $test_id;
                $currtest_cpy{'logstr'} = $currtest_cpy{'logstr'}."(".$currtest_cpy{'id'}.")";
                push(@tests, \%currtest_cpy);
                $test_id ++;
            }
        }
    }
}

### init_logs() ###
# Initializes the log files for each test run.
###
sub init_logs() {
    if ($verify::logfile ne "") {
        my $ec;

        if (-e $verify::logfile) {
            log_status("Logfile exists at ".Cwd::abs_path("./".$verify::logfile).". Backing up to ".Cwd::getcwd()."/verify.old.log".".\n");
            copy(Cwd::abs_path("./".$verify::logfile), Cwd::getcwd()."/verify.old.log");
        }

        log_status("Creating new log file ".Cwd::getcwd()."/".$verify::logfile."\n");
        $ec = open($logfile, ">".$verify::logfile);
        
        if ($ec == 0) {
            log_status("WARNING: Unable to open logfile for writing: $!\n");
            log_status("Log file will not be written.\n");
        }
        else {
            $logfile->autoflush(1);
        }
        
        log_status("Creating new log file ".Cwd::getcwd()."/".$verify::logfile.".error\n");
        $ec = open($errfile, ">".$verify::logfile.".error");
        
        if ($ec == 0) {
            log_status("WARNING: Unable to open logfile for writing: $!\n");
            log_status("Log file will not be written.\n");
        }
        else {
            $errfile->autoflush(1);
        }
    }
}

### finish() ###
# Exits the tool with a status code. Use this in place of Perl's built-in exit() elsewhere in the script. It also will handle log file cleanup and 
# emailing (if enabled).
###
sub finish( $ ) {
    my ($status) = @_;

    finish_logs();
    close($report_file) if ($report_file && $report_file->opened);

    if ($options{'email'}) {
        send_email();
    }

    log_status("Exiting with status $status.\n");
    log_status(localtime()."\n");
    close($statusfile) if ($statusfile && $statusfile->opened);

    chdir $root_dir;
    
    exit($status);
}

### send_email() ###
# Subroutine containing code for sending completion status email.
###
sub send_email() {
    log_status("Sending notification email to: ".$email_list."\n");
    my $status = system("mail -s 'Verify notification - ".$email_subject."' ".$email_list." < ".$root_dir."/".$verify::logfile);
    if ($status) {
        log_status("Error sending status email!\n");
        tlog(1, "Error sending status email!\n $!\n");
    }
}

### finish_logs() ###
# Simple method that closes log files.
###
sub finish_logs() {
    if ($logfile && $logfile->opened) {
        log_status("Closing log file.\n");
        close($logfile) or log_status("Failed attempt to close log file!\n");
    }

    if ($logfile && $errfile->opened) {
        log_status("Closing error log file.\n");
        close($errfile) or log_status("Failed attempt to close error log file!\n");
    }
}

### run_command() ###
# A wrapper for Perl's built-in system() function, for running commands in a shell. Use this function instead of system() in user-implemented code. It
# will provide proper handling of logging and console output so the user doesn't have to worry about it.
# Parameters:
#    - The command to run in a shell.
# Returns:
#    - The error code of the command after it exits the shell.
sub run_command( $ ) {
    my ($command) = @_;

    my $quiet_option = '';
    $quiet_option = ' > /dev/null' if ($options{'quiet'});

    if ($options{'null'}) {
        tlog(0, "[Execute] ".$command."\n");
        return 0;
    }
    else {
        log_status("Running user command: $command\n");
        my $pid = open(CMD, "-|");
        if ($pid) {
            # I'm the parent, echo the output
            $SIG{INT} = sub { kill(9, $pid); };
            while (<CMD>) {
                tlog(0, $_);
            }
            close(CMD);
            my $ec = $?;
            log_status("User command finished with return code: $ec\n");
            $SIG{INT} = "DEFAULT";
            return $ec;
        }
        else {
            # I'm the child, exec
            exec($command." 2>&1") or tdie("Failed trying to run command!\n$!\n");
        }
    }
}

### finish_child() ###
# Handles exiting the script, like the finish() function, but only when running as a child process in parallel mode.
# Parameters:
#   - The error code to exit with
###
sub finish_child( $ ) {
    my ($error_status) = @_;

    # If running in parallel mode, exit this fork
    if ($options{'parallel'} > 0) {
        log_status("Entering: ".Cwd::abs_path("..")."\n");
        chdir "..";

        POSIX::_exit($error_status);
    }
}

### log_report() ###
# If report logging is enabled, logs test status to report file.
# Parameters:
#   - The current test we are logging
#   - The error status from the test run
###
sub log_report( $$ ) {
    if ($report_file && $report_file->opened) {
        $report_semaphore->down();
        my ($test, $status) = @_;
        if ($status == 0) { # passed
            seek($report_file, 0, 2) and print $report_file "pass".$test->{'id'}.".log\t".$test->{'logstr'}."\tPASS\n";
        }
        else {
            seek($report_file, 0, 2) and print $report_file "fail".$test->{'id'}.".log\t".$test->{'logstr'}."\tFAIL\n";
        }
        $report_semaphore->up();
    }
}


################################################################################
## Signal handlers

###
# Interrupt signal handler to make sure all children exit cleanly if we trap ctrl+c while running in parallel mode.
###
$SIG{INT} = sub {
    # Kill all children
    log_status("Caught SIGINT\n");
    if ($options{'parallel'} > 0) {
        if (defined $is_child && $is_child == 0) {
            kill(9, keys(%children));
        }
        elsif (defined $is_child && $is_child == 1) {
            finish_child(9);
        }
    }
    
    finish(9);
};


################################################################################
## Main tool flow
# Initialize the tool
init();

# Do a sanity check to make sure we actually got a test to run.
if (@tests == 0) {
    tdie("No test was specified! Run with -h to get usage information.\n");
}

# Make a directory where everything will live (to keep things tidy)
mkdir "./verify" or tdie("Unable to create master directory! $!\n") if (!-d "./verify");
log_status("Entering: ".Cwd::abs_path("./verify")."\n");
chdir "./verify";

my $error_status = 0;

TEST_LOOP: foreach my $p_curr_test (@tests) {
    # Get current test
    my %curr_test = %$p_curr_test;

    # Test-specific error status
    my $test_status = 0;

    {
        #my $test_count = $test_count; # Save local copy of $test_count variable

        # String for logging...
        my $testline = $curr_test{'config'}."::".$curr_test{'name'}.(($curr_test{'params'} ne "") ? ",".$curr_test{'params'} : "" )."(".$curr_test{'id'}.")";

        # Initialize process if running in parallel mode
        my $pid;
        if ($options{'parallel'} > 0) {
            log_status("Waiting to fork test #".$curr_test{'id'}."...\n");

            # Here, wait for child processes to complete so we can fork off new ones without going over the specified limit
            while ( keys(%children) >= $options{'parallel'}) {
                my $kid = waitpid(-1, 0);
                my $kid_status = $?;

                if ($kid > 0) {
                    log_status("Child process (PID ".$kid.", test ".$children{$kid}.") exited with status ".$kid_status.".\n");
                    $error_status |= $kid_status;
                    delete $children{$kid};
                }
            }

            $pid = fork();
            tdie("Unable to fork!\n") unless defined $pid;

            if ($pid != 0) {
                # I'm the parent
                $is_child = 0;
                log_status("Forked child process (PID ".$pid.").\n");

                $children{$pid} = $curr_test{'logstr'};

                next TEST_LOOP;
            }
            else {
                # I'm the child
                $is_child = 1;
                log_status("Starting test = ".$curr_test{'logstr'}."\n");
            }
        }

        # Init steps
        $test_dir = Cwd::getcwd().'/'.$curr_test{'id'};
        mkdir $test_dir or tdie("Unable to create test directory! $!\n") if (!-d $test_dir);
        log_status("Entering: ".$test_dir."\n");
        chdir $test_dir or tdie("Unable to cd into test directory! $!\n");

        init_logs();
        log_status("Starting flow for test ".$curr_test{'id'}." - ".$curr_test{'config'}."::".$curr_test{'name'}.".\n");

        my $quietmode = $options{'quiet'};
        $options{'quiet'} = 0;
        tlog(0, "$me ".$curr_test{'logstr'}."\n");
        tlog(0, "Testing: ".$testline."\n");
        $options{'quiet'} = $quietmode;
        
        my $testfile_header = $curr_test{'config'}."_".$curr_test{'name'};
        if ($curr_test{'params'} ne "") {
            my $testfile_header_params = join('_', split(/,/, $curr_test{'params'}));
            $testfile_header = $testfile_header."__".$testfile_header_params;
        }

        unlink(glob("./*.")); # Delete any existing files so we don't accumulate any from previous runs
        open(TEMP, ">./${testfile_header}.") and close(TEMP) or tlog(1, "Failed to create test header file!\n");
        
        $verify::build_dir = Cwd::getcwd()."/1";
        $verify::run_dir = Cwd::getcwd()."/2";
        
        # Build flow
        if ($options{'build'} == 1) {
            mkdir $verify::build_dir or tdie("Unable to create build directory! $!\n") if (!-d $verify::build_dir);
            log_status("Entering: ".$verify::build_dir."\n");
            chdir $verify::build_dir or tdie("Unable to enter build directory! $!\n");

            build_test::pre_build(\%curr_test);
            $test_status = build_test::build(\%curr_test);
            build_test::post_build(\%curr_test);

            log_status("Build step finished with return code ".$test_status."\n");

            $error_status |= $test_status;
            
            log_status("Entering: ".Cwd::abs_path($test_dir)."\n");
            chdir $test_dir;
            
            # If build failed, log status and gracefully clean up logfiles, then continue to next test in list.
            if ($test_status > 0) {
                $email_subject = "Build failed!";
                log_status("Build of ".$testline." FAILED.\n");
                tlog(1, "Build of ".$testline." FAILED.\n");
                
                log_status("Entering: ".Cwd::abs_path("..")."\n");
                chdir "..";

                log_report(\%curr_test, $test_status);
                
                # Print out pass/fail status for each test as it completes
                $quietmode = $options{'quiet'}; # Backup quiet mode setting
                $options{'quiet'} = 0;
                
                if ($test_status == 0) {
                    log_status("Test ".$testline." PASSED.\n");
                    tlog(0, "Test ".$testline." PASSED.\n");
                }
                else {
                    log_status("Test ".$testline." FAILED.\n");
                    tlog(1, "Test ".$testline." FAILED.\n");
                }
                
                $options{'quiet'} = $quietmode;  # Restore quiet mode setting
                finish_logs();

                # Link logs to global area and rename if running multiple tests
                system("ln -sf ".$root_dir."/verify/".$curr_test{'id'}."/".$verify::logfile." ../".(($test_status > 0) ? "fail".$curr_test{'id'}.".log" : "pass".$curr_test{'id'}.".log" )) if (@tests > 1);

                if ($options{'parallel'} > 0 && $pid == 0) {
                    # If we're in parallel mode and I'm a child process, I should exit, instead of continuing to loop.
                    finish_child($test_status);
                }
                else {
                    # If we're not in parallel mode, I should continue to loop.
                    next TEST_LOOP;
                }
            }
        }
        
        
        # Simulation flow
        if ($options{'run'} == 1) {
            mkdir $verify::run_dir or tdie("Unable to create run directory! $!\n") if (!-d $verify::run_dir);
            log_status("Entering: ".$verify::run_dir."\n");
            chdir $verify::run_dir or tdie("Unable to enter run directory! $!\n");
            
            run_test::pre_run(\%curr_test);
            $test_status = run_test::run(\%curr_test);
            run_test::post_run(\%curr_test);

            log_status("Run step finished with return code ".$test_status."\n");

            $error_status |= $test_status;
            
            log_status("Entering: ".Cwd::abs_path($test_dir)."\n");
            chdir $test_dir;
            
        }
        
        log_report(\%curr_test, $test_status);

        log_status("Entering: ".Cwd::abs_path("..")."\n");
        chdir "..";

        # Print out pass/fail status for each test as it completes
        $quietmode = $options{'quiet'}; # Backup quiet mode setting
        $options{'quiet'} = 0;
        
        if ($test_status == 0) {
            log_status("Test ".$testline." PASSED.\n");
            tlog(0, "Test ".$testline." PASSED.\n");
        }
        else {
            log_status("Test ".$testline." FAILED.\n");
            tlog(1, "Test ".$testline." FAILED.\n");
        }
        
        $options{'quiet'} = $quietmode;  # Restore quiet mode setting

        # Link logs to global area and rename if running multiple tests
        system("ln -sf ".$root_dir."/verify/".$curr_test{'id'}."/".$verify::logfile." ../".(($test_status > 0) ? "fail".$curr_test{'id'}.".log" : "pass".$curr_test{'id'}.".log" )) if (@tests > 1);

        # Close logs for finished test and create links down tool path
        # NOTE: NO TEST LOGGING IS TO BE DONE PAST THIS LINE
        finish_logs();

        if ($options{'parallel'} > 0) {
            log_status("Finishing test instance: ".$testline."\n");
            finish_child($test_status);
        }
    }
}

# If only running a single test, create a link to its log with a plain name
if (@tests == 1) {
    $email_subject = "Simulation failed!" if ($error_status > 0);
    system("ln -sf ".$root_dir."/verify/".$tests[0]->{'id'}."/".$verify::logfile." ../".$verify::logfile);
} 

# Here, we got through all the tests. Now, if in parallel mode, wait for child processes to complete, then finish.
if ($options{'parallel'} > 0) {
    log_status("Waiting for all child processes to complete...\n");
    while ((my $kid = waitpid(-1, 0)) > 0) {
        log_status("Child process (PID ".$kid.", test ".$children{$kid}.") exited with status ".$?.".\n");
        delete $children{$kid};
    }

    log_status("All child processes have completed.\n");
}

# Pop down to home directory
log_status("Entering: ".Cwd::abs_path("..")."\n");
chdir "..";

# Gracefully exit
finish($error_status);

__END__

=head1 NAME

Verify - A simple verification tool to manage the definition, building, and running of tests in a verification environment.

=head1 SYNOPSIS

verify [options] I<config>::I<test>[,I<params>...] ...

 Options:
   -h, --help             Print usage information
   --man                  Display manpage-styled help
   --man2html             Writes manpage-styled help to a formatted HTML file
   -l, --log              Specifies log filename
   -d, --debug            Use debug mode
   -i, --interactive      Interactive debug mode
   -n                     Just print what would have run without running anything
   -e, --email            Email Verify status
   -q, --quiet            Quiet output
   -v, --verbose          Verbose output
   -p, --print            List available tests
   -P, --parallel         Run in parallel mode
   -r, --report           Enable test(s) pass/fail report logging
   --no-build             Skip build
   --build                Enable build
   --no-run               Skip run
   --run                  Enable run
   --version              Display version information

=head1 OPTIONS

=over 8

=item -h

=item --help

Shows this usage information.

=item --man

Displays a manpage-styled help documentation.

=item --man2html

Writes the same manpage-styled help displayed by C<--man> into an HTML-formatted file called F<verify.html>.

=item -l

=item --log

Specifies the name of the log file. Default is F<verify.log>.

=item -d

=item --debug

Enables debugging mode for the test(s). (Requires implementation in F<build_test.pm> and F<run_test.pm>.)

=item -i

=item --interactive

Enables debugging in interactive mode for the test(s). (Requires implementation in F<build_test.pm> and F<run_test.pm>.)

=item -n

Only print out what the tool would have done, without actually running anything in the shell.

=item --no-build

Skips the build step.

=item --build

Enables the build step (default). This will override previous usage of C<--no-build>.

=item --no-run

Skips the run step.

=item --run

Enables the run step (default). This will override previous usage of C<--no-run>.

=item -e

=item --email

Email results to one or more email recipients at tool completion.

=item -q

=item --quiet

Suppresses all console output.

=item -v

=item --verbose

Enables console output (default). This will override previous usage of C<--quiet>.

=item -p

=item --print

Causes Verify to find and list all available tests, and then exits.

=item -P

=item --parallel

Enables running of multiple tests in parallel. See the section called B<Running Tests> in the manual for more information.

=item -r

=item --report

When used, pass/fail status of all tests run will be recorded in a tab-delimited file F<report.txt>.

=item --version

Displays version information for Verify on the console.

=back

=head1 DESCRIPTION

=head2 Files, Installing, Configuring

=head3 Required files

This script was designed with portability in mind, so there are only a few files needed for basic script operation. The initial configuration step when installing this script is also very minimal. The whole of this script consists of at least three groups of files: the main source, indexing and parsing modules, and user-implemented modules for the build and run steps.

The main source is in F<verify.pl>. It contains all the code necessary for organizing and invoking tests. It will query the test file indexer (by default, F<TestIndex.pm>) and invoke the build and run steps from methods implemented in F<build_test.pm> and F<run_test.pm>, respectively. These two files may exist anywhere, so long as they are both in the same directory and that you configure F<verify.pl> to know where these files are. I will touch on configuration in the next subsection.

F<TestIndex.pm> contains the code necessary for resolving C<config::testname> pairs into its testfile. It utilizes test file parsing functions from F<TestFileParser.pm> to store the test definition into a hash variable. It also contains the code necessary for outputting the entire test list (if the tool is invoked with C<-p>).

F<build_test.pm> contains the code necessary for your build step. It implements three functions: C<pre_build()>, C<build()>, and C<post_build()>. The implementation of these functions is not provided, because they are to be written by the user. F<run_test.pm> is similar, but is associated with the run step. It implements three similar functions: C<pre_run()>, C<run()>, and C<post_run()>.

=head3 Installation and Configuration

To install this tool, simply store F<verify.pl> wherever you deem appropriate. Implement your F<build_test.pm> and F<run_test.pm> files and store those somewhere appropriate, as well. (Details for implementation of these files will be provided in the next subsection). This script requires a single environment variable to be set: C<$PRJ_HOME>. This points to the head of your verification environment.

Next, you have to tell the tool where your F<build_test.pm> and F<run_test.pm> files are, as well as where it should start looking for test files. To do this, create a file called F<verify.ini> and place it in C<$PRJ_HOME>. Open it in a text editor and any of the following:

    testsdir=./path/to/tests
    libsdir=./path/to/libs

C<testsdir> will specify the I<relative> path to your test files. It will cause the tool to start under C<$PRJ_HOME/testsdir> and recursively search for test definitions files. C<libsdir> tells the script where to look for your F<build_test.pm> and F<run_test.pm> files. This is also a relative path, under C<$PRJ_HOME>.

Your F<verify.ini> file can exclude either of these lines. Whatever the tool does not read in from this file, it will use the default.

B<NOTE:> This tool will I<always> look for the F<verify.ini> file in C<$PRJ_HOME>. If it does not exist, it will default C<testsdir> to C<$PRJ_HOME/verification/tests> and C<libsdir> to C<$PRJ_HOME/verification/scripts>. If there are any errors when it tries to pull in these modules (either due to compilation or file not found), it will cause this tool to die, logging out the error.

=head3 Implementing the Build and Run Steps

Templates for these two files are provided with the source code of this tool. You will notice that they are very sparse. They only contain three empty subroutine definitions, each. For both C<build()> and C<run()>, you will notice that there is an associated C<pre_*()> and C<post_*()> subroutine associated. As you might guess, these subroutines will be invoked before and after its corresponding method, respectively. You don't have to implement these functions, but they must exist. Otherwise, the Perl compiler will fail. I recommend using them for steps that are required as part of your build and run steps, but aren't directly involved in actually building or running the test itself. For instance, I use C<pre_build()> and C<pre_run()> to parse test parameters, and use C<post_run()> to allow me to invoke my debugging environment after a test completes, if desired. However, you can use them to do anything you'd like.

When implementing these functions, you should not use Perl's built-in C<print()> variants for displaying output to standard output. As there is an extensive output and logging mechanism built into the tool, anything you report using Perl's built-in functions will not be able to be captured in the log files. Instead, I provide a function for you to use instead:

    verify::tlog(level, message);

This function will display a message to your console, as well as log it. C<message> can be any string. C<level> can be either C<0> or C<1>. These level codes correspond to standard output and standard error, respectively. The power of this function is that if you run the test in regression mode (with C<--parallel>), or decide to force any console output to be suppressed (with C<--quiet>), any calls to C<tlog()> will suppress console output, but still output to the logfiles for reference later. Also, anything that you output using C<tlog()> with a level of C<1> will be both written to the log file, as well as a dedicated error log (named F<logfile.log.error>). This can be useful if you want to isolate errors for debug purposes.

Similarly, instead of using Perl's built-in C<system()> call for invoking shell commands, I provide another subroutine for you to use:

    verify::run_command(command_str);

This function behaves just as Perl's built-in C<system()> call, except it has a few additional capabilities. It will execute your command (stored in C<command_str>), retrieve the error code and return it back to the caller. However, it also will capture all output from the console and redirect it to the log file. Anything sent by the shell command to standard output and standard error will be displayed on the console and written to the log. It also has the capability to suppress console output in the same way as C<tlog()> provides. For logging purposes, it will also log the command that is being executed in the subshell. As an additional benefit, if you invoke the tool using C<-n> ("null" mode), it will cause the tool to follow all steps in a normal run but skip actual execution of your build and run tools. Using this command-line switch will tell C<verify::run_command()> to simply output the command it would have run, and return without actually running it.

As before, if you invoke any commands using Perl's built-in C<system()> call, you will not capture any of the test's output to the log files, nor be able to suppress console output. It also will not be able to skip running the command if you decide to invoke the tool using C<-n>.

Lastly, I have a replacement for Perl's built-in function, C<die()>. This will cause the tool to immediately exit, but I want to be able to control how the tool exits so that even in a case where a C<die()> call is appropriate, we will have potentially important information logged correctly. Instead of calling C<die()>, use:

    verify::tdie(message);

It does the same thing as Perl's C<die()>, but allows capturing of messages to our log files, and emailing results (if you enabled emailing when you invoked the tool).

Of course, I do not prevent you from using Perl's built-in C<print()> variants, nor C<system()> (and related). You may use them if you feel it would be useful. However, if you choose to do so, I believe you should be aware of the caveats of doing so.

=head2 Running Tests

=head3 General Usage

To specify what test(s) you wish to run, simply specify both its config and name together on the command line, as such:

    verify config::name

Verify will then search its database of tests for the test definition file containing this test. It will parse this file to gather any test information (such as test and tool parameters to use). This information will be passed to the build and run functions defined in the F<build_test.pm> and F<run_test.pm> files, which you will implement, with your build and run steps.

You may specify multiple tests to run in series by listing their config::name one after each other, separated with spaces, like so:

    verify config1::test1 config2::test2 ...

If you want to run the same test multiple times, you can use the repetition operator (C<{}>) instead of specifying the full test name multiple times. For instance, to run C<config1::test1> twice, you can type:

    verify config1::test1{2}

If you have test parameters, simply include them before the repetition operator:

    verify config1::test1,param1{2}

For more on test parameters, see the section called B<Test Parameters>.

=head3 Test Parameters

You may pass parameters to the test itself by including them following the test name plus a comma, as such:

    verify config::name,param1

You can pass any number of parameters to the test itself, this way:

    verify config::name,param1,param2,param3,param4

These parameters need not fulfill any particular syntax, so long as spaces and other special characters are properly escaped. You may parse these arguments as you see fit in the pre/post/build and pre/post/run subroutines in F<build_test.pm> and F<run_test.pm>. Therefore, they are most useful for directly configuring test build and run behavior from the command-line.

=head3 Running in Parallel Mode

If you use the C<--parallel> command-line option, you can specify a maximum number of tests allowed to run at once. This will cause Verify to run each test in its own separate process. At the same time, it will keep track of all currently running tests, logging test results and dispatching more as additional tests complete, until all tests have run. For example:

    verify --parallel 2 config1::test1 config2::test2 config3::test3

This executes all of the tests listed, while allowing for a maximum of 2 tests running in parallel. The Verify script will first run C<config1::test1> and C<config2::test2> in their own individual processes, which will be monitored by the main process. Once one of them completes, C<config3::test3> will be dispatched. Once all tests complete, error status is logged, and the script exits. This means that at any given time, if running in parallel mode for a setting of N available parallel slots, you will at any given time have no more than N+1 processes executing, and no more than N tests running simultaneously. Test dispatch is first-come-first-serve, in the order listed on the command-line.

Once all tests complete, Verify will exit with an status code indicating pass or failure. A code of zero means 'pass'. A code of non-zero means 'failed'. Actual fail codes are determined by the user-implemented F<build_test.pm> and F<run_test.pm> files. The final error status is a bitwise OR of these error codes. The script will exit indicating a failure if this final error status is non-zero.

=head2 Defining Tests

=head3 The files

The files required when writing a test are:

=over 2

=item *

F<Your test source>

=item *

F<testfile.test>

=back

These files will be assumed to live in F<$PRJ_HOME/verification/tests> by default. This can be redefined, however. See the subsection labelled B<Installation and Configuration> for more information.

The F<testfile.test> file is a simple text file containing the test definition. It has eight different keywords: C<test...endtest>, C<description>, C<config>, C<params>, C<build.args>, C<run.args>, C<define>.

B<NOTE:> You do not have to have an individual F<*.test> file per test, so long as there is a test definition associated with the test that exists in a F<*.test> file located somewhere where Verify can find it.

=head3 Descriptions of fields

=over 8

=item C<test>...C<endtest>

All test definitions are enclosed in a C<test...endtest> block (henceforth referred to as "test blocks"). These test blocks also are used to define the name of the test. The syntax is:

    test: test_name
      # Test info goes here
    endtest

The C<test_name> field is required.

=item C<description> 

A string containing a brief description of the test. This is a required field.

=item C<config>

This corresponds to your testbench configuration associated with this test. This is a required field.

=item C<build.args>

Contains a list of arguments to your build tool to be passed directly on the command-line. These arguments will not be parsed in any way, so be sure that they are well-formed!

=item C<run.args>

Contains a list of arguments to your test binary to be passed directly on the command-line. These arguments will not be parsed in any way, so be sure that they are well-formed!

=item C<params>

Contains a list of parameters to always use in addition to whatever is passed on the command-line as comma-separated test parameters.

=item C<define>

(Also: C<define build> and C<define run>)

You can use this to specify custom parameters for the test, which can be passed on the command-line by appending a comma after the test name and listing the comma-separated list of parameters. You can also list them in the test file using the C<params> line.

A C<define> line in a test file looks like this:

    define option1=+option1+1

If you specify C<option1> as a parameter when you invoke the test, C<+option1+1> will then be appended to the build and run tools' invocations using the C<build.args> and C<run.args> fields. Here's an example of how you invoke the test with this newly defined parameter:

    verify.pl config::test,option1

You can also create a define and specify that it should only apply to either the build tool or the run tool, like this:

    define build option2=+option2+1
      or
    define run option2=+option2+1

When using this method, C<+option2+1> will only be applied to its corresponding tool when the test is invoked using the C<option2> parameter.

You can also define parameters to accept strings. This will allow you to change build and run step behavior based on arbitrary values passed in when invoking the test. To do this, simply define your custom parameter as before, and use C<$$> to represent the string to replace. For example, this will define a custom parameter that lets you set a plusarg to some arbitrary value:

    define option3=+option3+$$

Now, you can invoke the test and set the plusarg C<+option3> to store any number or string you'd like. To do this, invoke the test with the parameter as such:

    verify.pl config::test,option3=15

This will then pass C<+option3+15> to your build and run tools as command-line arguments, setting the C<+option3> plusarg to 15.

If you want to define a test parameter so that it will pass C<$$> without substitution, simply escape it with a backslash (C<\>):

    define option4=+option4+\$$

When that backslash is present, it will not substitute the C<$$> out, and will pass the following to your build and run tools:

    +option4+$$

=back

B<NOTE:> F<Your test source> contains the code for your actual test. It may involve one or more files, depending on your verification methods and tool environment. Since the F<build_test.pm> and F<run_test.pm> files are user-implemented, identifying the test source may be done using values from one or more of these fields. Therefore, one must be conscious of the file and test naming conventions used.

=head1 VERSIONS

=over 3

=item *

I<v.2.3.1, July 19, 2013>

=over 3

=item Bugfixes:

=over 3

=item *

Reimplemented check for optional parameters in TestIndex so that they will not trigger false positives.

=item *

Disabling warning messages for $PRJ_HOME when simply getting help/version information when that variable isn't set in the environment.

=back

=item Enhancements:

=over 3

=item *

Putting the tool under GPLv2 and adding copyright notices to files.

=back

=back

=item *

I<v.2.3.0, July 12, 2013>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed some bugs in TestIndexCSV where if a new testfile has been added to the file tree, it wouldn't be properly indexed.

=back

=item Enhancements:

=over 3

=item *

Refactored test file parsing code, consolidating it into a module called TestFileParser.pm. This module simplifies test file reading and returns test file instructions using a standard format. TestIndex and TestIndexCSV now utilize this module for all test file parsing.

=item *

Aside from moving all test file parsing code to use the TestFileParser module, also did a lot of clean-up surrounding indexing code. Added some debug switches (accessible in the source code) to help with SQL statement debug.

=back

=back

=item *

I<v.2.2.2, June 17, 2013>

=over 3

=item Features:

=over 3

=item *

Adding a new module that uses CSV files and SQL queries for test indexing. Supports indexing of additional metadata alongside test name and file (for instance, line number). This should be more useful for indexing tests in a few, very large .test files.

=back

=back

=item *

I<v2.2.1, June 13, 2013>

=over 3

=item Enhancements:

=over 3

=item *

Switched over from using a flat, sequential text file for the index, to using the Berkeley DB_FILE format and a BTree container structure. This should allow indexes to scale to larger sizes without introducing a significant performance penalty.

=back

=back

=item *

I<v2.2.0, May 13, 2013>

=over 3

=item NOTE:

With this release, I'm migrating the tool to the GitHub repository.

=item Bugfixes:

=over 3

=item *

Moved the checking whether $PRJ_HOME is set from compile-time to run-time so you don't have to set it just to view the help documentation.

=back

=back

=item *

I<v2.1.1, April 25, 2013>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug where test parameters that pass a value to build and run might lose the value, especially when specified by using the C<params> field in the test file.

=back

=item Features:

=over 3

=item *

Finally adding a C<--version> switch with version information.

=back

=item Enhancements:

=over 3

=item *

For log files, changed from using hard links and relative paths to symbolic links and absolute paths.

=item *

If a log file froma  previous run is found it will now be backed up to verify.old.log before being overwritten.

=back

=back

=item *

I<v2.1, February 15, 2013>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug where if you specify a test that doesn't exist in the index, the reindexing process would end up deleting the entire index and then rebuilding it from scratch every time.

=item *

Fixed a bug where if you ran a list of tests one after the other, the script would fail when trying to create log files for the second test in the list.

=item *

When running in parallel mode, if the build step failed for a test, it would still attempt to continue running the test, instead of properly exiting and continuing to the next test in the list.

=item *

Pass/Fail statuses reported when running with the C<-n> switch contradicted each other (logging FAIL while logfile is named F<pass*.log>). Fixed so now it's reported as a FAIL throughout the tool output.

=item *

When run with certain command-line switches that cause the tool to exit immediately (for instance, C<--help> or C<--print>), it would never generate the F<verify_status.env> log of environment variables. Now it does.

=back

=item Features:

=over 3

=item *

Added the repetition operator so that you can tell the tool to repeat tests an arbitrary number of times without typing the full test name out more than once.

=item *

Added the C<-r>/C<--report> switch to enable pass/fail reports for the list of tests to be saved at run.

=item *

Added the C<--man2html> switch for a more readable option for the manpage help.

=back

=item Enhancements:

=over 3

=item *

Changed the C<run_command()> implementation to use Perl IPCs instead of C<system()> and appending tee to the file. This makes the logging mechanism a bit more robust.

=item *

Overhauled the formatting for the manpage help, for readability and to make the HTML generated help nicer as well.

=back

=back

=item *

I<v2.0, December 18, 2012>

=over 3

=item Features:

=over 3

=item *

Overhauled the test parsing code, now implemented in a module called F<TestIndexParser.pm>. This new parser updates the test definition file syntax and greatly increases its flexibility and scalability. We now support having multiple test definitions within a single F<*.test> file, through the use of test blocks. Also, test files now may exist anywhere underneath the location specified by the C<testsdir> configuration option, instead of being confined to F<C<testsdir>/config/testname.test>. In order to reduce filesystem access time, this tool will also transparently maintain a test index, to allow quick and direct access to the associated test file when running a test.

=back

=back

=item *

I<v1.3, December 13, 2012>

=over 3

=item Enhancements:

=over 3

=item *

Extracted test parsing code into a separate module called F<TestParser.pm>, and modified the tool to call this file. This is in preparation for a future revision allowing for greater enhancement of the test parsing and management system.

=back

=back

=item *

I<v1.2.6, November 29, 2012>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug where if the tool failed when trying to include the F<build_test.pm> and F<run_test.pm> modules, it would fail silently, and cause the verify tool to fail. Now, the script will die with the specific, more descriptive error.

=back

=item Features:

=over 3

=item *

Extended the ability to configure the Verify tool using F<verify.ini>. Now it will look for its configuration in C<$PRJ_HOME>. It also now supports configuring where to find F<build_test.pm> and F<run_test.pm>. Instead of loading these files at compile time, it will load them at run time, which enables us to configure from where it should load them based on what we read in from the file.

=item *

Extended custom test parameters to allow passing in values. Now, any instance of double dollar signs (C<$$>) will be replaced with anything you put to the right of the equals sign when passing the parameter on the command-line.

=back

=item Enhancements:

=over 3

=item *

Updated the documentation to include a section describing how to install and configure the tool, as well as some basic information about implementing the build and run flows.

=back

=back

=item *

I<v1.2.5, November 20, 2012>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed enforcement of required fields in test files. The script now checks that they exist and will error if any are missing.

=back

=item Features:

=over 3

=item *

Added the ability to define test-specific parameter options from within the F<*.test> files. You can list these on the command-line as comma-separated strings, or include them in the C<params> line as default parameters in the F<*.test> files themselves.

=back

=item Enhancements:

=over 3

=item *

Since C<--debug> and C<--interactive> are supposed to set flags that are acted upon by the user code in build_test.pm and run_test.pm, this script now sets dedicated global flags, so the user doesn't have to use the C<%options>.

=item *

In response to the previously listed enhancement, C<%options> has now been made private to the main script file, instead of global. This will protect the script from being put into undefined configuration states through errant user code.

=back

=back

=item *

I<v1.2.1, October 26, 2012>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug that caused zero-length files to accumulate when doing multiple runs over the same directory. Not a critical bug, but it eventually would run into the filesystem limit if left unchecked.

=back

=item Features:

=over 3

=item *

Added ability to specify directory where test files are stored using a configuration file.

=back

=item Enhancements:

=over 3

=item *

Updated script logging for readability and to reflect paths where script and tests are stored.

=back

=back

=item *

I<v1.2, October 18, 2012>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug where if the build step fails, log files weren't cleanly finished and links to the log files weren't created.

=item *

Removed some stale code for debug mode since it is no longer handled in the main script.

=item *

Fixed a bug exposed when running a list of tests, where if one or more tests fail while the last test in the list passes, the script will return with exit code '0' (pass). This causes the script to effectively forget about the error status of previous tests, and incorrectly report the test results.

=item *

Added enforcement of making the C<-i>/C<--interactive> command-line option override use of C<-d>/C<--debug> so that they are mutually exclusive.

=back

=item Features:

=over 3

=item *

Enhanced comment parsing in F<*.test> files to allow you to include C<#> characters by escaping them C-style (C<\#>).

=back

=item Enhancements:

=over 3

=item *

Updated help documentation with more descriptions on running tests and more organized formatting in VERSIONS section.

=back

=back

=item *

I<v1.1, August 28, 2012>

=over 3

=item Bugfixes:

=over 3

=item *

Fixed a bug preventing errors to be logged to the error logfile.

=back

=item Features:

=over 3

=item *

Added additional test fields to allow for individual customization of build and run steps.

=item *

Added the ability to hard-code test parameters into test files as an alternative to passing them on the command-line.

=item *

Added version information to manpage-style documentation.

=back

=back

=item *

I<v1.0, August 17, 2012>

=over 3

=item

Initial revision.

=back

=back

=head1 AUTHORS

Benjamin D. Richards

=head1 COPYRIGHT

This tool is licensed under the GNU GENERAL PUBLIC LICENSE Version 2 (GPLv2). See F<COPYRIGHT> for its terms.

=cut



