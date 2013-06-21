#!/bin/sh

echo "Setting up test environment..."
VERIFY_HOME=..

export PRJ_HOME=`echo $PWD | sed 's/ /\\ /g'`
alias verify='$VERIFY_HOME/verify.pl'

echo "Cleaning test environment for use..."
rm -rf $PRJ_HOME/.verify
rm verify_status verify_status.env

echo "Testing..."
verify -h
verify -p
verify c1::example1
