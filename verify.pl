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
my $usagefile = "README.pod";
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
                             'help|h'        => sub { Pod::Usage::pod2usage(-input => "$install_dir/$usagefile", -verbose => 1, -exitval => 'NOEXIT'); finish(0); },
                             'man'           => sub { Pod::Usage::pod2usage(-input => "$install_dir/$usagefile", -verbose => 2, -exitval => 'NOEXIT'); finish(0); },
                             'man2html'      => sub { Pod::Html::pod2html("--header", "--infile=$install_dir/$usagefile", "--outfile=README.html"); finish(0); },
                             'version'       => sub { tlog(0, $verify::VERSION." developed by ".$verify::AUTHOR." [".$verify::REPOSITORY."]\n\n".$verify::COPYRIGHT."\n"); finish(0); }
        ) or Pod::Usage::pod2usage(-input => "$install_dir/$usagefile", -verbose => 0, -exitval => 'NOEXIT') and tdie("Command option parsing failed.\n");

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
    
    exit(($status & 0x7F) ? ($status | 0x80) : ($status >> 8));
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
        log_status("Exiting with status: ".$error_status."\n");
        POSIX::_exit(($error_status & 0x7F) ? ($error_status | 0x80) : ($error_status >> 8));
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
        
        
        # Run flow
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
        my $kid_status = $?;
        log_status("Child process (PID ".$kid.", test ".$children{$kid}.") exited with status ".$kid_status.".\n");
        $error_status |= $kid_status;
        delete $children{$kid};
    }

    log_status("All child processes have completed.\n");
}

# Pop down to home directory
log_status("Entering: ".Cwd::abs_path("..")."\n");
chdir "..";

# Gracefully exit
finish($error_status);
