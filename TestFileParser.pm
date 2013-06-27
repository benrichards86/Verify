# TestFileParser.pm
# Parses a line of text read from a text file and returns a data structure containing instruction information.
# Written by Benjamin Richards, (c) 2013

use strict;
use Tie::File;
use Fcntl 'O_RDONLY';

package verify::TestFileParser;

my @instr_fields = qw/keyword modifier scope data data_action/;

# Instruction format:
# Keyword:       Modifier:   Scope:     Data:     Data2:   Data_action:
# ---------------------------------------------------------------------
#  test          N/A         N/A        string    N/A      N/A          = Scoping instructions...
#  endtest       N/A         integer    N/A       N/A      N/A          
#  name          N/A         integer    string    N/A      N/A          = Declarative instructions...
#  config        N/A         integer    string    N/A      N/A           
#  description   N/A         integer    string    N/A      N/A           
#  params        N/A         integer    string    N/A      =, +=         
#  define        build       integer    string    string   =, +=         
#  define        run         integer    string    string   =, +=         
#  define        (none)      integer    string    string   =, +=         

# Scope identifies what the current instruction is associated with.
# State machine for parsing:
# ((test)) -> [create new scope] -> [assign name] -> (declarative instruction) --+--> (endtest) -> [destroy scope] -|
#   /^\                                                         /^\              |                                  |
#    |                                                           |_______________+                                  |
#    |                                                                           |                                  |
#    |                                                                           +-> (other) -> [Die with error]    |
#    |______________________________________________________________________________________________________________|

# Function prototypes
sub TestFileParser::open( $ );
sub TestFileParser::close();
sub TestFileParser::get_next_instruction();
sub prune( $ );
sub plog( $$ );

# Global variables
$TestFileParser::filename = "";

# Local variables
my @file_arr;
my $file_index = 0;
my $current_scope = -1;

my $scoping_mode = -1;  # 0 for multiple tests per file, 1 for single test per file

my $next_scope_number = 0;

### plog() ###
# Logs a message to standard output or standard error.
# Parameters:
#   - 0 for standard output, 1 for standard error.
#   - String message to log.
###
sub plog( $$ ) {
    if (exists &verify::tlog) {
        verify::tlog(@_);
    }
    else {
        if ($_[0] == 0) {
            print $_[1];
        }
        else {
            print STDERR $_[1];
        }
    }
}

### open() ###
# Opens a file for parsing. Note that this module is state-based, so you cannot have multiple files open concurrently.
# Parameters:
#   - The full path and filename to the file we wish to open.
# Returns:
#   - Non-zero if successful, 0 if failed.
###
sub TestFileParser::open( $ ) {
    $TestFileParser::filename = $_[0];
    tie @file_arr, 'Tie::File', $TestFileParser::filename, mode => Fcntl::O_RDONLY;
    if (@file_arr) {
        $file_index = 0;
        
        # TODO: need to figure out how to detect scoping mode. Hard-code to 0 for now.
        $scoping_mode = 0;

        if ($scoping_mode == 1) {  # Define new scope on file open if scoping mode is single test per file
            $current_scope = $next_scope_number;
            $next_scope_number ++;
        }

        return !0;
    }
    else {
        return 0;
    }
}

### close() ###
# Closes the file currently opened for parsing.
###
sub TestFileParser::close() {
    if (@file_arr) {
        untie @file_arr;
    }
}

### get_next_instruction() ###
# Parses the next instruction in the file (if file is opened).
# Returns:
#   - List of values defining the parsed instruction, according to the 
#     table above, if a file is opened and there exists a next 
#     instruction to parse, OR...
#   - An empty list if there is no file open or a valid next instruction.
###
sub TestFileParser::get_next_instruction() {
    if (!@file_arr) {
        return ();
    }

    my @instruction = ();
    my ($keyword, $modifier, $scope, $data, $data2, $data_action);

    my $curr_line;

    do {
        if ($file_index >= @file_arr) {
            return ();
        }

        $curr_line = $file_arr[$file_index];
        $file_index ++;
        
        $curr_line = prune($curr_line);
    } while ($curr_line =~ m/^$/);

    if ($curr_line =~ m/^test:\s*(\w+)$/) {
        if ($current_scope != -1) {
            plog(1, "Error: Test scopes cannot be nested!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "test";
        $data = $1;
        $current_scope = $next_scope_number;
        $scope = $current_scope;

        undef $modifier;
        undef $data2;
        undef $data_action;
    }
    elsif ($curr_line =~ m/^endtest$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Found 'endtest' with no matching 'test'!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "endtest";
        $scope = $current_scope;
        $current_scope = -1;
        $next_scope_number ++;

        undef $modifier;
        undef $data;
        undef $data2;
        undef $data_action;
    }
    elsif ($curr_line =~ m/^name=(\w+)$/) {  # 'name' keyword (for scoping mode 1)
        if ($scoping_mode != 1) {
            plog(1, "Error: Keyword 'name' not allowed for scoping mode 0!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }
        if ($current_scope == -1) {
            plog(1, "Error: No scope was set!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "name";
        $scope = $current_scope;
        $data = $1;
        undef $data_action;
        undef $data2;
        undef $modifier;
    }
    elsif ($curr_line =~ m/^define\s+(\w+\s+)?\w+(\+=|=).*$/) { # 'define' keyword
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'define' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        if ($curr_line =~ m/^define\s+(\w+)(\+=|=)(.+)$/) {  # no modifier
            $keyword = "define";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
            undef $modifier;
        }
        elsif ($curr_line =~ m/^define\s+build\s+(\w+)(\+=|=)(.+)$/) {  # 'build' modifier
            $keyword = "define";
            $modifier = "build";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
        }
        elsif ($curr_line =~ m/^define\s+run\s+(\w+)(\+=|=)(.+)$/) {  # 'run' modifier
            $keyword = "define";
            $modifier = "run";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
        }
        else {
            $curr_line =~ m/^define\s+(\w+)\s+\w+=.*$/;
            plog(1, "Error: Unexpected argument to 'define' in test definition file!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }
    }
    elsif ($curr_line =~ m/^description=(.*)$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'description' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "description";
        $scope = $current_scope;
        $data = $1;
        undef $modifier;
        undef $data2;
        undef $data_action;
    }
    elsif ($curr_line =~ m/^config=(.*)$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'config' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "config";
        $scope = $current_scope;
        $data = $1;
        undef $modifier;
        undef $data2;
        undef $data_action;
    }
    elsif ($curr_line =~ m/^params(\+=|=)(.*)$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'params' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "params";
        $scope = $current_scope;
        $data_action = $1;
        $data = $2;
        undef $modifier;
        undef $data2;
    }
    else {
        plog(1, "Error: Bad syntax!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
        return ();
    }

    @instruction = ($keyword, $modifier, $scope, $data, $data2, $data_action);

    return @instruction;
}

### prune() ###
# Prunes comments and extra whitespace from a string.
# Parameters:
#   - A string to prune
# Returns:
#   - The pruned string
###
sub prune( $ ) {
    my $curr = $_[0];
    if ($curr ne "") {
        if ($curr =~ m/(?<=\\)#.*/) {
            $curr =~ s/\\(#.*)/$1/g;  # Not a comment, just remove backslash escaping
        } else {
            $curr =~ s/(?<!\\)#.*//g; # remove comments from test file
        }
    }

    $curr =~ s/^\s*//g;
    $curr =~ s/\s*$//g;

    return $curr;
}

1;
