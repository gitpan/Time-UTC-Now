use Config qw(%Config);
use ExtUtils::MakeMaker;

sub compile_and_link_ok($$) {
	my($hdrs, $code) = @_;
	my $incs = join("", map { "#include <$_>\n" } @$hdrs);
	open(TESTSRC, ">conftest.c") or die $!;
	print TESTSRC "#include \"EXTERN.h\"\n".
		"#include \"perl.h\"\n".
		"#include \"XSUB.h\"\n".
		"#include \"ppport.h\"\n".
		$incs."int main(void) { $code }\n";
	close(TESTSRC);
	my $cmd = "$Config{cc} $Config{ccflags} -I$Config{archlibexp}/CORE ".
		"$Config{ldflags} -o conftest$Config{exe_ext} conftest.c";
	print "testing: ", (map { "<$_> " } @$hdrs), $code, "\n", $cmd, "\n";
	return !system($cmd);
}

print "configuring...\n";
my $defs = "";
$defs .= " -DQUSE_NTP_ADJTIME"
	if compile_and_link_ok(["sys/timex.h"],
		"struct timex tx; int st; st = ntp_adjtime(&tx);");
$defs .= " -DQHAVE_STRUCT_TIMEX_TIME"
	if compile_and_link_ok(["sys/timex.h"],
		"struct timex tx; tx.time.tv_sec = 0; return tx.time.tv_sec;");
$defs .= " -DQHAVE_STRUCT_TIMEX_TIME_TV_NSEC"
	if compile_and_link_ok(["sys/timex.h"],
		"struct timex tx; tx.time.tv_nsec = 0; return tx.time.tv_nsec;");
$defs .= " -DQHAVE_STRUCT_TIMEX_TIME_STATE"
	if compile_and_link_ok(["sys/timex.h"],
		"struct timex tx; tx.time_state = 0; return tx.time_state;");
$defs .= " -DQHAVE_STRUCT_NTPTIMEVAL_TIME_TV_NSEC"
	if compile_and_link_ok(["sys/timex.h"],
		"struct ntptimeval ntv; ntv.time.tv_nsec = 0; return ntv.time.tv_nsec;");
$defs .= " -DQHAVE_STRUCT_NTPTIMEVAL_TIME_STATE"
	if compile_and_link_ok(["sys/timex.h"],
		"struct ntptimeval ntv; ntv.time_state = 0; return ntv.time_state;");
$defs .= " -DQUSE_GETTIMEOFDAY"
	if compile_and_link_ok(["sys/time.h"],
		"struct timeval tv; int st; st = gettimeofday(&tv, NULL);");

WriteMakefile(
	NAME => "Time::UTC::Now",
	VERSION_FROM => "lib/Time/UTC/Now.pm",
	PREREQ_PM => {
		Data::Float => "0.000",
		Math::BigRat => "0.02",
		Module::Runtime => "0.001",
		Time::Unix => "1.02",
		XSLoader => 0,
	},
	DEFINE => $defs,
	clean => { FILES => "conftest*" },
);
