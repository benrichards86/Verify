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
#  config        N/A         integer    string    N/A      N/A          = Declarative instructions... 
#  description   N/A         integer    string    N/A      N/A           
#  params        N/A         integer    string    N/A      =, +=        
#  build.args    N/A         integer    string    N/A      =, +=
#  run.args      N/A         integer    string    N/A      =, +=
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
sub TestFileParser::parse_parameter( $$ );
sub TestFileParser::seek( $ );
sub TestFileParser::get_current_position();
sub prune( $ );
sub plog( $$ );

# Global variables
$TestFileParser::filename = "";

# Local variables
my @file_arr;
my $file_index = 0;
my $current_scope = -1;

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
        $file_index = 0;
        $current_scope = -1;
        $next_scope_number = 0;
    }
}

### seek() ###
# Seeks to a specific line in the file. Warning: This can be unsafe as it ignores scoping within the file.
# Parameters:
#   - Line to seek to (relative to the beginning of the file, starting at 0).
# Returns:
#   - Non-zero for success, 0 for failed.
###
sub TestFileParser::seek( $ ) {
    if (@file_arr && $_[0] >= 0 && $_[0] < @file_arr) {
        $file_index = $_[0];
        return !0;
    }
    else {
        return 0;
    }
}

### get_current_position() ###
# Returns the current location we are in the file.
# Returns:
#   - Integer. 0 if haven't read yet. -1 if no file open or end of file.
###
sub TestFileParser::get_current_position() {
    if ($file_index == -1 || $file_index > @file_arr) {
        return -1;
    }
    else {
        return $file_index;
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

        $modifier = '';
        $data2 = '';
        $data_action = '';
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

        $modifier = '';
        $data = '';
        $data2 = '';
        $data_action = '';
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
            $modifier = '';
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
    elsif ($curr_line =~ m/^build\.args(=|\+=)(.*)$/) {
        $keyword = "build.args";
        $scope = $current_scope;
        $data_action = $1;
        $data = $2;
        $modifier = '';
        $data2 = '';
    }
    elsif ($curr_line =~ m/^run\.args(=|\+=)(.*)$/) {
        $keyword = "run.args";
        $scope = $current_scope;
        $data_action = $1;
        $data = $2;
        $modifier = '';
        $data2 = '';
    }
    elsif ($curr_line =~ m/^description=(.*)$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'description' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "description";
        $scope = $current_scope;
        $data = $1;
        $modifier = '';
        $data2 = '';
        $data_action = '';
    }
    elsif ($curr_line =~ m/^config=(.*)$/) {
        if ($current_scope == -1) {
            plog(1, "Error: Keyword 'config' only allowed within a test's scope!\n [".$TestFileParser::filename." @ ".$file_index."]  ".$curr_line."\n");
            return ();
        }

        $keyword = "config";
        $scope = $current_scope;
        $data = $1;
        $modifier = '';
        $data2 = '';
        $data_action = '';
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
        $modifier = '';
        $data2 = '';
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
    # Remove comments
    $curr =~ s/(?<!\\)#.*//g;

    # Removed backslash escaping for non-comment # characters
    $curr =~ s/\\(#.*)/$1/g;

    # Remove trailing and prefixed whitespace
    $curr =~ s/^\s*//g;
    $curr =~ s/\s*$//g;

    return $curr;
}


### parse_parameter() ###
# Takes a test parameter and parses it, applying any substitutions when necessary.
# Parameters:
#   - Test parameter to parse
#   - The argument value
# Returns:
#   - The test parameter with substitutions applied
###
sub TestFileParser::parse_parameter( $$ ) {
    my $param = $_[0];
    my $argvalue = $_[1];

    # Substitute $$ in param value for argument (or empty string, if it expected one but didn't get one). (Can avoid substitution by using \$$.)
    $param =~ s/(?<!\\)\$\$/$argvalue/;

    return $param;
}

1;
