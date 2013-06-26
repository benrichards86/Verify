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
sub TestFileParser::prune( $ );

# Global variables
$TestFileParser::filename = "";

# Local variables
my @file_arr;
my $file_index = 0;
my $current_scope = -1;

my $scoping_mode = -1;  # 0 for multiple tests per file, 1 for single test per file

my $next_scope_number = 0;

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

    my $currline;

    do {
        $currline = $file_arr[$file_index];
        $file_index ++;
        
        $currline = TestFileParser::prune($currline);
    } while ($currline =~ m/^$/ );


    if ($currline =~ m/^test:\s*(\w+)$/) {
        if ($current_scope != -1) {
            #TODO: error...
        }

        $keyword = "test";
        $data = $1;
        $current_scope = $next_scope_number;

        undef $modifier;
        undef $scope;
        undef $data2;
        undef $data_action;
    }
    elsif ($currline =~ m/^endtest$/) {
        if ($current_scope == -1) {
            #TODO: error...
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
    elsif ($currline =~ m/^name=(\w+)$/) {  # 'name' keyword (for scoping mode 1)
        if ($scoping_mode != 1) {
            #TODO: error...
        }
        if ($current_scope == -1) {
            #TODO: error...
        }

        $keyword = "name";
        $scope = $current_scope;
        $data = $1;
        undef $data_action;
        undef $data2;
        undef $modifier;
    }
    elsif ($currline =~ m/^define\s+(\w+\s+)?\w+(\+=|=).*$/) { # 'define' keyword
        if ($current_scope == -1) {
            #TODO: error...
        }

        if ($currline =~ m/^define\s+(\w+)(\+=|=)(.+)$/) {  # no modifier
            $keyword = "define";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
            undef $modifier;
        }
        elsif ($currline =~ m/^define\s+build\s+(\w+)(\+=|=)(.+)$/) {  # 'build' modifier
            $keyword = "define";
            $modifier = "build";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
        }
        elsif ($currline =~ m/^define\s+run\s+(\w+)(\+=|=)(.+)$/) {  # 'run' modifier
            $keyword = "define";
            $modifier = "run";
            $scope = $current_scope;
            $data = $1;
            $data_action = $2;
            $data2 = $3;
        }
        else {
            #TODO: error...

            #$currline =~ m/^define\s+(\w+)\s+\w+=.*$/;
            #verify::tdie("Unexpected argument to define in test definition file! Line: ".TEST->input_line_number()."\n File: ".$testfile."\n Argument: ".$1."\n");
        }
    }
    elsif ($currline =~ m/^description=(.*)$/) {
        if ($current_scope == -1) {
            #TODO: error...
        }

        $keyword = "description";
        $scope = $current_scope;
        $data = $1;
        undef $modifier;
        undef $data2;
        undef $data_action;
    }
    elsif ($currline =~ m/^config=(.*)$/) {
        if ($current_scope == -1) {
            #TODO: error...
        }

        $keyword = "config";
        $scope = $current_scope;
        $data = $1;
        undef $modifier;
        undef $data2;
        undef $data_action;
    }
    elsif ($currline =~ m/^params(\+=|=)(.*)$/) {
        if ($current_scope == -1) {
            #TODO: error...
        }

        $keyword = "params";
        $scope = $current_scope;
        $data_action = $1;
        $data = $2;
        undef $modifier;
        undef $data2;
    }
    else {
        #TODO: error...
    }

    @instruction = ($keyword, $modifier, $scope, $data, $data2, $data_action);

    #### DEBUG ####
    print "[ ".join(",", @instruction)." ]\n";
    #### DEBUG ####
    
    return @instruction;
}

### prune() ###
# Prunes comments and extra whitespace from a string.
# Parameters:
#   - A string to prune
# Returns:
#   - The pruned string
###
sub TestFileParser::prune( $ ) {
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
