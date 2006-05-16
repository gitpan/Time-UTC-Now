use Config qw(%Config);
use ExtUtils::MakeMaker;

sub compile_and_link_ok($$) {
	my($hdrs, $code) = @_;
	$hdrs = join("", map { "#include <$_>\n" } @$hdrs);
	open(TESTSRC, ">conftest.c") or die $!;
	print TESTSRC "#include \"EXTERN.h\"\n".
		"#include \"perl.h\"\n".
		"#include \"XSUB.h\"\n".
		"#include \"ppport.h\"\n".
		$hdrs."int main(void) { $code }\n";
	close(TESTSRC);
	my $cmd = "$Config{cc} $Config{ccflags} -I$Config{archlibexp}/CORE ".
		"$Config{ldflags} -o conftest$Config{exe_ext} conftest.c";
	print $cmd, "\n";
	return !system($cmd);
}

print "configuring...\n";
my $defs = "";
$defs .= " -DQUSE_NTP_ADJTIME"
	if compile_and_link_ok(["sys/timex.h"],
		"struct timex tx; int st; st = ntp_adjtime(&tx);");
$defs .= " -DQUSE_GETTIMEOFDAY"
	if compile_and_link_ok(["sys/time.h"],
		"struct timeval tv; int st; st = gettimeofday(&tv, NULL);");

WriteMakefile(
	NAME => "Time::UTC::Now",
	VERSION_FROM => "lib/Time/UTC/Now.pm",
	PREREQ_PM => {
		"Math::BigRat" => "0.02",
		"Module::Runtime" => "0.001",
		"Time::Unix" => "1.02",
	},
	DEFINE => $defs,
	clean => { FILES => "conftest*" },
);
