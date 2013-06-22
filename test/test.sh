#!/bin/sh
# test.sh
# Runs tests on Verify tool.

# Set up test environment
VERIFY_HOME=..
export PRJ_HOME=`echo $PWD | sed 's/ /\\ /g'`
alias verify='$VERIFY_HOME/verify.pl'

function echo_error {
    echo "test.sh> Failed!" &1> /dev/stderr
    exit -1
}

function echo_pass {
    echo "test.sh> Ok!"
}

function clean {
    echo "Cleaning test environment..."
    rm -rf $PRJ_HOME/.verify $PRJ_HOME/verify $PRJ_HOME/verify_status* $PRJ_HOME/verify.log
}

function test {
    echo "Testing..."
    verify -h
    verify -p
    ( verify c1::example1 || echo_error ) && echo_pass
    ( verify c2::example3 || echo_error ) && echo_pass
    ( verify c1::example4 && echo_error) || echo_pass
}

function usage {
    echo "test.sh"
    echo "Runs tests on the Verify tool."
    echo "(c) Benjamin Richards, 2013"
    echo ""
    echo "Usage:"
    echo "  test.sh [target]"
    echo ""
    echo "Targets:"
    echo "  clean  - Cleans test environment of temporary, result, and log files."
    echo "  test   - Runs the tests."
    echo "  usage  - Prints this usage information."
    echo ""
    exit;
}

type $1 > /dev/null || usage

$1


