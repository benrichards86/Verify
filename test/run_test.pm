# Template for run_test.pm. It should be modified and stored somewhere inside your
# project tree.
use strict;
package verify::run_test;


# This is the test parameter list.
my %params = ( 
    'example_param' => 0,           # Example parameter
    'example_string_param' => ''    # Example string parameter
);


# This function gets executed directly before the run step. I like to use it to parse
# test parameters. It can be used for anything you'd like. It returns no value. It accepts
# a single parameter containing a hash for the current test.
sub run_test::pre_run( $ ) {
    my %test = %{$_[0]};

    # Pulling in test parameters for build configuration later
    my %custom_params = (%{$test{'run.define'}}, %{$test{'define'}});
    my @test_params = split(',', $test{'params'});
    foreach my $curr (@test_params) {
	if ($curr =~ m/=/) {
	    my ($key, $value) = ($`, $'); #'); # Closing what emacs sees as a single-quote string to fix font-lock mode
            if (exists($params{$key})) {
                $params{$key} = $value;
            }
            elsif (!exists($custom_params{$key})) {
                verify::tlog(0, "Warning: Unrecognized run parameter: $key\n");
            }
	}
	else {
            if (exists($params{$curr})) {
                $params{$curr} = 1;
            }
            elsif (!exists($custom_params{$curr})) {
                verify::tlog(0, "Warning: Unrecognized run parameter: $curr\n");
            }
	}
    }

}


# This function gets executed for the run step. It should return the error condition. It
# accepts a single parameter containing a hash for the current test.
sub run_test::run( $ ) {
   my %test = %{$_[0]};
   verify::tlog(0, "Run step for test:\n");
   foreach my $k (keys %test) {
       verify::tlog(0, "  $k => $test{$k}\n");
       if (ref($test{$k}) eq 'HASH') {
           my %curr = %{$test{$k}};
           if (keys(%curr) > 0) {
               foreach my $k2 (keys %curr) {
                   verify::tlog(0, "    $k2 => $curr{$k2}\n");
               }
           }
           else {
               verify::tlog(0, "    -- empty --\n");
           }
       }
   }

   ## This is an example of parameter handling. All parameters are stored in the
   ## %params hash and can be accessed in any method.
   my $example_option = "";
   if ( $params{'example_param'} ) {
       $example_option = some value;
   }
   my $example_string_option = $params{'example_string_param'};

   ## This is an example of how to run the build step. You use the run_command()
   ## subroutine to run any external commands.
   my $return_code = verify::run_command("make --directory $verify::testsdir run ${example_option} ${example_string_option}");

   ## This is how you log output to the console and logfile. You should use the
   ## tlog() function. 0 is for STDOUT, 1 is for STDERR.
   if ($return_code == 0) {
      verify::tlog(0, "Run passed.\n");
   }
   else {
      verify::tlog(1, "Run failed.\n");
   }

   ## At the end, return the error condition, so the tool can pick it up.
   return $return_code;
}


# This function gets executed after the run step regardless of success or failure. It returns
# no value. It accepts a single parameter containing a hash for the current test.
sub run_test::post_run( $ ) {
    my %test = %{$_[0]};

}


1;
