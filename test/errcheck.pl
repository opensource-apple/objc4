#!/usr/bin/perl
use strict;

# errcheck.pl
# Check test output for errors.
# usage: test.out | errcheck.pl test [stderr-file]

my $testname = shift || die;
my $errfile = shift || "$testname.expected-stderr";

my @input;
my @original_input;
while (my $line = <>) {
    chomp $line;
    push @input, $line;
    push @original_input, $line;
}

# Run result-checking passes, reducing @input each time
my $xit = 0;
my $bad = "";
$bad |= filter_valgrind() if ($ENV{VALGRIND});
$bad = filter_expected() if ($bad eq ""  &&  -e $errfile);
$bad = filter_bad()  if ($bad eq "");

# OK line should be the only one left
$bad = "(output not 'OK: $testname')" if ($bad eq ""  &&  (scalar(@input) != 1  ||  $input[0] !~ /^OK: $testname/));

if ($bad ne "") {
    my $red = "\e[41;37m";
    my $def = "\e[0m";
    $xit = 1;
    print "${red}BAD: /// test '$testname' \\\\\\$def\n";
    for my $line (@original_input) {
	print "$red $def$line\n";
    }
    print "${red}BAD: \\\\\\ test '$testname' ///$def\n";
    print "${red}FAIL: ## $testname: $bad$def\n";
} else {
    print "PASS: $testname\n";
}

exit $xit;

sub filter_expected
{
    my $bad = "";

    open(my $checkfile, $errfile) 
	|| die "can't find $errfile\n";
    my $check = join('', <$checkfile>);
    close($checkfile);

    my $input = join("\n", @input) . "\n";
    if ($input !~ /^$check$/s) {
	$bad = "(didn't match $errfile)";
	@input = "BAD: $testname";
    } else {
	@input = "OK: $testname";  # pacify later filter
    }

    return $bad;
}

sub filter_bad
{
    my $bad = "";

    my @new_input;
    for my $line (@input) {
	chomp $line;
	if ($line =~ /^BAD: (.*)/) {
	    $bad = "(failed)";
	} else {
	    push @new_input, $line;
	}
    }
    @input = @new_input;
    return $bad;
}

sub filter_valgrind
{
    my $errors = 0;
    my $leaks = 0;

    my @new_input;
    for my $line (@input) {
	if ($line =~ /^Approx: do_origins_Dirty\([RW]\): missed \d bytes$/) {
	    # --track-origins warning (harmless)
	    next;
	}
	if ($line !~ /^^\.*==\d+==/) {
	    # not valgrind output
	    push @new_input, $line;
	    next;
	}

	my ($errcount) = ($line =~ /==\d+== ERROR SUMMARY: (\d+) errors/);
	if (defined $errcount  &&  $errcount > 0) {
	    $errors = 1;
	}

	(my $leakcount) = ($line =~ /==\d+==\s+(?:definitely|possibly) lost:\s+([0-9,]+)/);
	if (defined $leakcount  &&  $leakcount > 0) {
	    $leaks = 1;
	}
    }

    @input = @new_input;

    my $bad = "";
    $bad .= "(valgrind errors)" if ($errors);
    $bad .= "(valgrind leaks)" if ($leaks);
    return $bad;
}
