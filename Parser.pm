# Parser.pm
# Parses a line of text read from a text file and returns a data structure containing instruction information.
# Written by Benjamin Richards, (c) 2013

use strict;

package verify::Parser;

my @instr_fields = qw/keyword modifier scope data data_action/;

# Instruction format:
# Keyword:       Modifier:   Scope:     Data:     Data_action:
# ------------------------------------------------------------
#  test          N/A         N/A        string    N/A          } Scoping instruction
#  endtest       N/A         integer    N/A       N/A          }
#  name          N/A         integer    string    N/A          } Declarative instruction 
#  config        N/A         integer    string    N/A          } 
#  description   N/A         integer    string    N/A          } 
#  params        N/A         integer    string    +, +=        } 
#  define        build       integer    string    +, +=        } 
#  define        run         integer    string    +, +=        } 
#  define        (none)      integer    string    +, +=        } 

# Scope identifies what the current instruction is associated with.
# State machine for parsing:
# ((test)) -> [create new scope] -> [assign name] -> (declarative instruction) --+--> (endtest) -> [destroy scope] -|
#   /^\                                                         /^\              |                                  |
#    |                                                           |_______________+                                  |
#    |                                                                           |                                  |
#    |                                                                           +-> (other) -> [Die with error]    |
#    |______________________________________________________________________________________________________________|

