#!/bin/sh
# do.sh
# Runs tests on Verify tool and libraries.

# Set up test environment
VERIFY_HOME=..
export PRJ_HOME=`echo $PWD | sed 's/ /\\ /g'`
alias verify='$VERIFY_HOME/verify.pl'

function clean {
    echo "Cleaning test environment..."
    make --directory $PRJ_HOME clean
    rm -rf $PRJ_HOME/.verify $PRJ_HOME/verify $PRJ_HOME/verify_status* $PRJ_HOME/verify.log
}

function _run_test_expect_fail {
    verify $1
    if [[ $? == 0 ]]; then
        echo "do.sh> Failed!" > /dev/stderr
        echo ""
        exit 255
    else
        echo "do.sh> Ok!"
        echo ""
    fi
}

function _run_test_expect_pass {
    verify $1
    if [[ $? > 0 ]]; then
        echo "do.sh> Failed!" > /dev/stderr
        echo ""
        exit 255
    else
        echo "do.sh> Ok!"
        echo ""
    fi
}

function test {
    echo "Testing..."
    _run_test_expect_pass -h
    _run_test_expect_pass -p
    _run_test_expect_pass c1::example1
    _run_test_expect_pass c2::example3
    _run_test_expect_fail c1::example4
}

function help {
    echo "do.sh"
    echo "Runs tests on the Verify tool."
    echo "(c) Benjamin Richards, 2013"
    echo ""
    echo "Usage:"
    echo "  do.sh [target]"
    echo ""
    echo "Targets:"
    echo "  clean       - Cleans test environment of temporary, result, and log files."
    echo "  test        - Runs the tests."
    echo "  test_parser - Runs a canned test on the TestFileParser module."
    echo "  help        - Prints this usage information."
    echo ""
    exit;
}

function test_parser {
    perl -I.. -E '
use TestFileParser;

TestFileParser::open("example1.test");
my @instruction;

do {
    @instruction = TestFileParser::get_next_instruction();
    print "Got instruction: [".join(",",@instruction)."]\n";
} while(@instruction);

TestFileParser::close();
exit;
'

}

if [[ `type -t $1` == "function" ]]; then
    $1
else
    echo "Invalid option: $1" > /dev/stderr
    echo ""
    help
fi


